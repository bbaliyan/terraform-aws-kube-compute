# SPDX-License-Identifier: Apache-2.0
# Named worker instances rather than an autoscaling group. See README.md for why
# that is the right way round for a cluster that stops every evening.
locals {
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  # An IAM name_prefix caps at 38 characters, and this one carries two variable
  # parts. Capping the whole string can cost the trailing hyphen, which is only
  # cosmetic -- AWS appends its own unique suffix regardless. substr is a no-op
  # below the limit, so no existing role's prefix changes.
  node_iam_name_prefix = substr(format("kube-compute-%s-%s-", var.cluster_name, var.group_name), 0, 38)

  effective_ami_id = coalesce(
    var.os_image_ami_id,
    try(one(data.aws_ami.by_name[*].id), null),
  )

  availability_zone = data.aws_subnet.selected.availability_zone

  # Keys start at 1, matching aws-control-plane's own cp-1/cp-2 naming.
  node_keys = { for i in range(var.node_count) : tostring(i + 1) => i + 1 }
  node_names = {
    for k, n in local.node_keys : k => (
      var.node_name_template == null
      ? "${var.group_name}-${var.cluster_name}-${k}"
      : replace(replace(var.node_name_template, "{zone}", substr(local.availability_zone, length(local.availability_zone) - 1, 1)), "{number}", format("%02d", n))
    )
  }

  # Run on the node at join time, so the token is never in user_data.
  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  # node-group is derived from group_name so a nodeSelector needs no separately
  # passed label duplicating a name the caller already gave.
  node_labels = merge(
    {
      "topology.kubernetes.io/zone" = local.availability_zone
      "kube-compute.io/node-group"  = var.group_name
    },
    var.node_labels,
  )

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    NodeGroup   = var.group_name
    ManagedBy   = "kube-compute"
  })
}

# One role per group, not per node: every node reads the same SSM parameter.
module "node_iam" {
  source = "../node-iam"

  name_prefix           = local.node_iam_name_prefix
  tags                  = local.common_tags
  aws_region            = var.aws_region
  attach_ebs_csi_policy = var.attach_ebs_csi_policy
  agent_token = {
    policy_name   = "kube-compute-${var.cluster_name}-${var.group_name}-agent-token-read"
    ssm_parameter = var.agent_token_ssm_parameter
  }
}

module "boot_steps" {
  source = "../boot-steps"

  aws_provider_id = var.aws_provider_id
}

# One render per node, which is what lets set_hostname stay true here: an ASG's
# members share a single render and so cannot each carry a distinct hostname.
module "node_bootstrap" {
  source   = "../node-bootstrap"
  for_each = local.node_keys

  cluster_name              = var.cluster_name
  node_name                 = local.node_names[each.key]
  node_fqdn_label           = "${var.group_name}-${each.key}"
  cluster_fqdn_suffix       = var.cluster_fqdn_suffix
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  node_taints               = var.node_taints
  trusted_ca_pem            = var.trusted_ca_pem
  trusted_ca_in_image       = var.trusted_ca_in_image
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
  provider_steps            = module.boot_steps.steps
  graceful_shutdown         = var.graceful_shutdown
  os_auto_updates           = var.os_auto_updates
}

# No depends_on: RKE2's agent retries its join indefinitely, so a worker booting
# alongside genesis simply waits.
resource "aws_instance" "node" {
  depends_on = [var.destroy_after]

  for_each = local.node_keys

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = module.node_iam.instance_profile_name

  # hop_limit 3, not AWS's documented 2. Confirmed live that 2 is one hop short
  # of a pod's IMDSv2 token PUT getting its response back: IMDSv2 caps that
  # response's TTL to hop_limit, and Cilium's pod-netns routing costs 2 hops.
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
    tags                  = merge(local.common_tags, { Name = "${local.node_names[each.key]}-root" })
  }

  user_data_base64 = base64gzip(module.node_bootstrap[each.key].cloud_init_user_data)

  tags = merge(local.common_tags, { Name = local.node_names[each.key] })

  lifecycle {
    # Don't replace on AMI patch drift; remove to deliberately upgrade.
    ignore_changes = [ami, user_data_base64]
  }
}
