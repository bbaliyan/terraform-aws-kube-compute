# SPDX-License-Identifier: Apache-2.0
# Tokens owned here directly, matching proxmox-control-plane's precedent. Two tokens for
# least privilege: server token joins etcd/control-plane; agent token is all a worker gets,
# so a compromised worker can't rejoin as control-plane/etcd.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

locals {
  # node-bootstrap renders each node's whole user data.
  combined_user_data = { for k, m in module.node_bootstrap : k => m.cloud_init_user_data }

  # EC2 rejects RunInstances when decoded user data exceeds 16384 bytes. Static
  # content is kept out of the payload for that reason: the genesis node reads the
  # Cilium render from the platform ref, and a CA can be baked (trusted_ca_in_image). The bootstrap
  # program is in the payload with its comments removed. The precondition on the
  # instance turns AWS's rejection into a message naming the inputs that fix it.
  inline_user_data_bytes = {
    for k, v in local.combined_user_data : k => floor(length(base64gzip(v)) / 4) * 3
  }

  # Arch from AWS's own metadata — covers all present and future instance types.
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  effective_ami_id = coalesce(
    var.os_image_ami_id,
    try(one(data.aws_ami.by_name[*].id), null),
  )

  # VPC ID resolved from vpc_name, or null when vpc_name is not provided.
  named_vpc_id = try(data.aws_vpc.named[0].id, null)

  # subnet_name is the one-element case of subnet_names; both variables funnel into this list so the
  # lookup and selection below have a single shape to deal with.
  subnet_name_candidates = var.subnet_names != null ? var.subnet_names : (var.subnet_name != null ? [var.subnet_name] : [])

  # Whether the caller pinned placement at all. When they did not, the default-VPC fallback applies.
  has_explicit_subnet = var.subnet_id != null || length(local.subnet_name_candidates) > 0

  # Whether the subnet comes from subnet_names, the only case where the module chooses one.
  chooses_subnet = var.subnet_id == null && length(local.subnet_name_candidates) > 0

  # For a new cluster, the first candidate in the caller's order with room for every node it
  # launches with. A subnet with some free addresses but too few would be chosen, then fail the
  # apply partway through.
  roomy_subnet_id = try([
    for name in local.subnet_name_candidates :
    data.aws_subnet.by_name[name].id
    if data.aws_subnet.by_name[name].available_ip_address_count >= var.subnet_min_free_ips
  ][0], null)

  # input, not output: output is unknown until the first apply, and the plan of a new cluster
  # must already know its subnet.
  named_subnet_id = try(terraform_data.subnet_choice[0].input, null)

  # Network handle: explicit subnet_id → named subnet → first default-VPC subnet. Never creates fabric.
  # Wrapped in try so that resolving to nothing stays null: coalesce raises on all-null arguments,
  # and its "no non-null arguments" error would surface instead of the preconditions below, which
  # can actually say which of the two ways to end up with no subnet happened.
  effective_subnet_id = try(coalesce(var.subnet_id, local.named_subnet_id, try(sort(data.aws_subnets.default[0].ids)[0], null)), null)

  # DNS is optional and name-only. cluster_fqdn is the API/kubeconfig name; wildcard covers it + services.
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  # coalesce() errors if every argument is null (the common case: no DNS configured at
  # all), so a plain conditional is used instead — it tolerates both being null.
  effective_zone_id = var.hosted_zone_id != null ? var.hosted_zone_id : try(data.aws_route53_zone.private[0].zone_id, null)
  create_record     = local.has_domain && local.effective_zone_id != null

  # An IAM name_prefix caps at 38 characters, where a security group's does not,
  # and cluster_name allows up to 31 -- so a legal name could fail at apply after
  # the rest of the plan had already been created. substr returns the whole string
  # when it is shorter than the limit, so this changes no existing role's prefix.
  node_iam_name_prefix = format("kube-compute-%s-", substr(var.cluster_name, 0, 24))

  # Split from create_record so another module can own the wildcard without
  # costing the cluster its api. record, which is what agents join through.
  create_wildcard_record = local.create_record && var.manage_wildcard_dns_record

  # cluster_type drives the taint, never worker count: node pools are separate state this
  # module cannot see, and node counts alone are ambiguous (double-duty HA vs dedicated CP).
  control_plane_taint = var.cluster_type == "dedicated_control_plane"

  # The map's own keys ARE the distinct AZs — no data source needed to discover them.
  distinct_control_plane_azs = var.control_plane_subnets != null ? sort(keys(var.control_plane_subnets)) : []

  # One subnet per control-plane node, round-robin across distinct AZs (e.g. 5 nodes in a
  # 3-AZ region); the >= 3 AZ requirement below is still enforced.
  control_plane_subnet_ids = var.control_plane_count > 1 && length(local.distinct_control_plane_azs) > 0 ? [
    for i in range(var.control_plane_count) :
    var.control_plane_subnets[local.distinct_control_plane_azs[i % length(local.distinct_control_plane_azs)]]
  ] : []

  # control_plane_count = 1 keeps the single-subnet resolution unchanged; HA takes the first
  # AZ slot. try() guards an empty control_plane_subnet_ids list so evaluation fails via the
  # precondition below with a clear message, not a raw index-out-of-range crash.
  genesis_subnet_id = var.control_plane_count > 1 ? try(local.control_plane_subnet_ids[0], local.effective_subnet_id) : local.effective_subnet_id

  # HA mode derives VPC from the control-plane subnets themselves, not the single-node
  # fallback (unused once control_plane_count > 1) — avoids creating SGs/the NLB target
  # group in a different VPC than where instances actually launch.
  #
  # For a subnet_names cluster the VPC comes from the candidate lookup that holds the chosen
  # subnet, not from data.aws_subnet.selected. That data source reads the choice resource, so
  # on the first plan after an upgrade it waits for the apply, the VPC is unknown, and the
  # security groups would be replaced. The candidates do not wait.
  chosen_candidate_vpc_ids = [for s in data.aws_subnet.by_name : s.vpc_id if s.id == local.named_subnet_id]
  chosen_candidate_azs     = [for s in data.aws_subnet.by_name : s.availability_zone if s.id == local.named_subnet_id]
  module_vpc_id = (
    var.control_plane_count > 1 ? data.aws_subnet.control_plane_genesis[0].vpc_id
    : length(local.chosen_candidate_vpc_ids) > 0 ? local.chosen_candidate_vpc_ids[0]
    : data.aws_subnet.selected.vpc_id
  )

  # Null when control_plane_count = 1. Otherwise depends on endpoint_mode: NLB DNS name
  # (loadbalancer, default), shared Route53 record (dns), or static_registration_address (static).
  registration_address = var.control_plane_count == 1 ? null : (
    var.endpoint_mode == "static" ? var.static_registration_address :
    var.endpoint_mode == "dns" ? local.dns_registration_name :
    try(aws_lb.control_plane[0].dns_name, null)
  )

  # dns mode's shared record name, distinct from cluster_fqdn (the kubeconfig/API-cert
  # name). Null unless a domain is configured; enforced by the precondition on
  # aws_instance.control_plane below.
  dns_registration_name = local.has_domain ? "cp.${local.fqdn_suffix}" : null

  # All control-plane instances, keyed by node number (1, 2, ...), for per-node
  # DNS/health-check/alarm resources.
  control_plane_instances = {
    for k, inst in aws_instance.control_plane : tostring(tonumber(k) + 1) => inst
  }

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

# The subnet chosen from subnet_names, kept in state so the cluster stays there. The candidates are
# read afresh on every plan: without this, a subnet that filled up after the cluster was placed
# would move it, replacing every node and leaving its EBS volumes in the zone it left. The choice
# is held here rather than by ignore_changes on the instances, because the security groups' VPC,
# the zone in node names and the subnet that workers follow all derive from it too.
resource "terraform_data" "subnet_choice" {
  count = local.chooses_subnet ? 1 : 0

  input = local.roomy_subnet_id

  lifecycle {
    ignore_changes = [input]
  }
}

# ---- Delivery: the agent token is mirrored into an SSM SecureString and fetched at
# boot via the worker's own instance IAM role — never rendered into user_data.
resource "aws_ssm_parameter" "agent_token" {
  name  = "/kube-compute/${var.cluster_name}/agent-token"
  type  = "SecureString"
  value = random_password.agent_token.result
  tags  = local.common_tags
}

# All-protocol among members (not pinned to today's CNI ports) so it outlives a CNI
# switch. Owned here rather than a separate module since aws-node-pool attaches to it
# by real ID (vpc_security_group_ids) — a hard AWS API dependency, unlike Proxmox's
# name-based ipsets.
resource "aws_security_group" "cluster" {
  name_prefix = "kube-compute-${var.cluster_name}-cluster-"
  description = "kube-compute ${var.cluster_name}: east-west traffic among cluster members only."
  vpc_id      = local.module_vpc_id
  tags        = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "all traffic among cluster members"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.cluster.id
  tags                         = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster-self" })
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster-egress-all" })
}

# Key "0" is genesis (server-init); every other key joins it (server-join). The
# GitOps inputs reach genesis only: the platform bootstrap runs on the first server.
# A joining node gets each input's node-bootstrap default, so its render is the
# same as when it had a module call of its own.
#
# node-bootstrap renders at plan time and runs nothing, so a joining node that
# boots before genesis is ready relies on RKE2's own join retry. Ordering among
# the joining nodes (one etcd learner at a time) is handled by bootstrap.sh.
module "boot_steps" {
  source = "../boot-steps"

  aws_provider_id = var.aws_provider_id
}

module "node_bootstrap" {
  for_each = { for i in range(var.control_plane_count) : tostring(i) => i }

  source = "../node-bootstrap"

  cluster_name                    = var.cluster_name
  node_name                       = local.control_plane_names[each.key]
  node_fqdn_label                 = "cp-${each.value + 1}"
  cluster_fqdn                    = local.cluster_fqdn
  cluster_fqdn_suffix             = local.fqdn_suffix
  node_role                       = each.key == "0" ? "server-init" : "server-join"
  control_plane_taint             = local.control_plane_taint
  cluster_token                   = random_password.server_token.result
  cluster_agent_token             = each.key == "0" ? random_password.agent_token.result : null
  registration_address            = local.registration_address
  extra_tls_sans                  = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  trusted_ca_pem                  = var.trusted_ca_pem
  trusted_ca_in_image             = var.trusted_ca_in_image
  registry_mirror_url             = var.registry_mirror_url
  dns_servers                     = var.dns_servers
  gitops_platform_enabled         = each.key == "0" ? var.gitops_platform_enabled : true
  gitops_platform_repo_url        = each.key == "0" ? var.gitops_platform_repo_url_override : null
  gitops_platform_revision        = each.key == "0" ? var.gitops_platform_revision_override : null
  gitops_workloads_repo_url       = each.key == "0" ? var.gitops_workloads_repo_url : null
  gitops_workloads_revision       = each.key == "0" ? var.gitops_workloads_revision : "main"
  gitops_workloads_path           = each.key == "0" ? var.gitops_workloads_path : "."
  workloads_extra_helm_parameters = each.key == "0" ? var.workloads_extra_helm_parameters : {}
  workloads_helm_values_object    = each.key == "0" ? var.workloads_helm_values_object : null
  cert_mode                       = var.cert_mode
  platform_extra_helm_parameters  = each.key == "0" ? var.platform_extra_helm_parameters : {}
  platform_helm_values_object     = each.key == "0" ? var.platform_helm_values_object : null
  extra_tags                      = var.extra_tags
  provider_steps                  = module.boot_steps.steps
  graceful_shutdown               = var.graceful_shutdown
  os_auto_updates                 = var.os_auto_updates
}

# No registration endpoint for control_plane_count = 1. Internal NLB is the default HA mode
# on cloud (a floating VIP can't cross AZ boundaries); see endpoint_mode for dns/static.
resource "aws_lb" "control_plane" {
  count              = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  name_prefix        = "cp-lb-"
  internal           = true
  load_balancer_type = "network"
  subnets            = distinct(local.control_plane_subnet_ids)
  tags               = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp" })
}

resource "aws_lb_target_group" "control_plane" {
  count       = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  name_prefix = "cp-tg-"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = local.module_vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "6443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp" })
}

resource "aws_lb_listener" "control_plane" {
  count             = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  load_balancer_arn = aws_lb.control_plane[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.control_plane[0].arn
  }
}

resource "aws_lb_target_group_attachment" "genesis" {
  count            = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  target_group_arn = aws_lb_target_group.control_plane[0].arn
  target_id        = aws_instance.control_plane["0"].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "additional" {
  for_each         = var.endpoint_mode == "loadbalancer" ? { for k, inst in aws_instance.control_plane : k => inst if k != "0" } : {}
  target_group_arn = aws_lb_target_group.control_plane[0].arn
  target_id        = each.value.id
  port             = 6443
}

# Route53's public health checkers can't reach a private VPC IP, so each health check is
# CLOUDWATCH_METRIC-type, backed by that instance's own EC2 status-check alarm — the
# standard bridge for private-IP Route53 failover.
resource "aws_cloudwatch_metric_alarm" "control_plane_health" {
  for_each = var.control_plane_count > 1 && var.endpoint_mode == "dns" ? local.control_plane_instances : {}

  alarm_name          = "kube-compute-${var.cluster_name}-cp-${each.key}-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  dimensions = {
    InstanceId = each.value.id
  }
  tags = local.common_tags
}

resource "aws_route53_health_check" "control_plane" {
  for_each = var.control_plane_count > 1 && var.endpoint_mode == "dns" ? local.control_plane_instances : {}

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.control_plane_health[each.key].alarm_name
  cloudwatch_alarm_region         = var.aws_region
  insufficient_data_health_status = "Unhealthy"
  tags                            = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp-${each.key}" })
}

resource "aws_route53_record" "control_plane_dns" {
  for_each = var.control_plane_count > 1 && var.endpoint_mode == "dns" ? local.control_plane_instances : {}

  zone_id                          = local.effective_zone_id
  name                             = local.dns_registration_name
  type                             = "A"
  ttl                              = 10
  records                          = [each.value.private_ip]
  set_identifier                   = "cp-${each.key}"
  health_check_id                  = aws_route53_health_check.control_plane[each.key].id
  multivalue_answer_routing_policy = true
}

# ---- Module-owned security group (NOT fabric) ----
resource "aws_security_group" "node" {
  name_prefix = "kube-compute-${var.cluster_name}-"
  description = "kube-compute ${var.cluster_name}: cluster access ports only, no SSH."
  vpc_id      = local.module_vpc_id
  tags        = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}" })

  lifecycle {
    # create_before_destroy avoids a name_prefix collision when the SG is replaced. The
    # instance's SG re-association is a separate apply step, so this is not zero-downtime.
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node" {
  for_each = { for p in var.ingress_ports : tostring(p) => p }

  security_group_id = aws_security_group.node.id
  description       = "cluster access port ${each.value}"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  # One rule per port spanning the first allowed CIDR; remaining CIDRs handled below.
  cidr_ipv4 = var.allowed_ingress_cidrs[0]
  tags      = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-ingress-${each.value}" })
}

# Additional CIDRs beyond the first, per port.
resource "aws_vpc_security_group_ingress_rule" "node_extra" {
  for_each = {
    for pair in setproduct(var.ingress_ports, slice(var.allowed_ingress_cidrs, 1, length(var.allowed_ingress_cidrs))) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.node.id
  description       = "cluster access port ${each.value.port}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-ingress-${each.value.port}" })
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-egress-all" })
}

module "node_iam" {
  source = "../node-iam"

  name_prefix = local.node_iam_name_prefix
  tags        = local.common_tags
  aws_region  = var.aws_region
}

# One instance per control-plane node; key "0" is genesis. The precondition fails plan
# explicitly when control_plane_count > 1 but fewer than 3 distinct AZs resolved, rather
# than silently under-spreading the quorum. The other nodes are left out of for_each
# then, so the precondition reports it and not an index error.
#
# A resource cannot depend on its own instances, so the nodes start together. A
# joining node retries until genesis answers.
resource "aws_instance" "control_plane" {
  for_each = {
    for i in range(var.control_plane_count) : tostring(i) => try(local.control_plane_subnet_ids[i], local.genesis_subnet_id)
    if i == 0 || length(local.control_plane_subnet_ids) > 0
  }

  depends_on = [var.destroy_after]

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.node.id, aws_security_group.cluster.id]
  iam_instance_profile   = module.node_iam.instance_profile_name

  # hop_limit 3, not AWS's commonly-documented 2. Confirmed live: with hop_limit 2, a pod's
  # IMDSv2 token PUT completes its TCP handshake (proving pod<->host routing works) but the
  # token response never arrives ("Operation timed out ... 0 bytes received"). IMDSv2 caps
  # that response's TTL to hop_limit as an anti-SSRF control, and it's dropped one hop
  # short — Cilium's veth + pod-netns routing costs 2 hops here, not the 1 hop AWS's generic
  # guidance assumes. Mutable in place (not ForceNew) — no replacement needed to pick this up.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "${local.control_plane_names[each.key]}-root" })
  }

  user_data_base64 = base64gzip(local.combined_user_data[each.key])

  tags = merge(local.common_tags, { Name = local.control_plane_names[each.key] })

  lifecycle {
    # Don't replace on AlmaLinux 10 AMI patch drift; remove to deliberately upgrade.
    ignore_changes = [ami, user_data_base64]

    precondition {
      condition     = var.control_plane_count == 1 || length(local.distinct_control_plane_azs) >= 3
      error_message = "control_plane_count > 1 requires at least 3 distinct availability zones among the resolved control-plane subnets (got ${length(local.distinct_control_plane_azs)}); pass control_plane_subnets spanning >= 3 AZs."
    }

    precondition {
      # EC2 rejects RunInstances over 16384 decoded bytes, and by then this plan has
      # created the role, the security groups and the token parameter. The payload's
      # size is not knowable until apply -- it carries a generated token -- so this
      # runs at apply and names the input that fixes it.
      condition     = local.inline_user_data_bytes[each.key] <= 16384
      error_message = "This node's boot payload is larger than EC2 allows in user data (16384 decoded bytes). What travels in it should be per-cluster values, not static content: set trusted_ca_in_image if the node image bakes the CA, and look at what the platform Application's Helm values are carrying."
    }

    precondition {
      condition     = var.endpoint_mode != "dns" || (local.has_domain && local.effective_zone_id != null)
      error_message = "endpoint_mode = \"dns\" requires cluster_domain to be set and a resolvable hosted zone (hosted_zone_id or hosted_zone_name)."
    }
  }
}

# api.<cluster>.<domain>, always explicit rather than left to the wildcard above.
# DNS answers the most specific name, so this keeps pointing at the control plane
# even where the wildcard points at nodes that do not serve the API.
resource "aws_route53_record" "api" {
  count   = local.create_record ? 1 : 0
  zone_id = local.effective_zone_id
  name    = local.cluster_fqdn
  type    = "A"
  ttl     = 60
  records = [aws_instance.control_plane["0"].private_ip]
}

# Created only when cluster_domain is set and a zone is resolvable. Otherwise register
# *.${cluster}.${domain} -> cluster_ip yourself using the wildcard_dns_name output.
resource "aws_route53_record" "wildcard" {
  count   = local.create_wildcard_record ? 1 : 0
  zone_id = local.effective_zone_id
  name    = local.wildcard_name
  type    = "A"
  ttl     = 60
  records = [aws_instance.control_plane["0"].private_ip]
}

locals {
  control_plane_zones = {
    for i in range(var.control_plane_count) : tostring(i) => (
      var.control_plane_count > 1 && length(local.distinct_control_plane_azs) > 0
      ? local.distinct_control_plane_azs[i % length(local.distinct_control_plane_azs)]
      : length(local.chosen_candidate_azs) > 0 ? local.chosen_candidate_azs[0]
      : data.aws_subnet.selected.availability_zone
    )
  }

  control_plane_names = {
    for k, zone in local.control_plane_zones : k => (
      var.node_name_template == null
      ? "cp-${var.cluster_name}-${tonumber(k) + 1}"
      : replace(replace(var.node_name_template, "{zone}", substr(zone, length(zone) - 1, 1)), "{number}", format("%02d", tonumber(k) + 1))
    )
  }
}
