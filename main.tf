# SPDX-License-Identifier: Apache-2.0

# A local as well as an output: generated .tf files (terragrunt's generate block)
# can reference a module's locals but not its outputs.
locals {
  all_instance_ids = concat(
    [for name, ref in module.control_plane.control_plane_node_refs : ref.instance_id],
    flatten([for name, group in module.static_nodes : group.instance_ids]),
  )

  autoscaling_enabled = length(var.autoscaled_nodes) > 0

  # Every node that launches with the cluster into the control plane's subnet: the control plane
  # and each static node without a subnet of its own. The subnet a new cluster is placed in must
  # have this many free addresses.
  launch_ip_count = sum(concat([1], [for group in var.static_nodes : group.node_count if group.subnet_id == null]))

  platform_node_iam_role_name = coalesce(
    one([for name, group in module.static_nodes : group.node_iam_role_name if name == var.platform_node_group]),
    module.control_plane.node_iam_role_name,
  )

  workload_node_iam_role_names = concat(
    var.cluster_type == "dedicated_control_plane" ? [] : [module.control_plane.node_iam_role_name],
    [for group in module.static_nodes : group.node_iam_role_name],
    [for role in module.autoscaled_nodes : role.node_iam_role_name],
  )

  platform_helm_values_object = merge(
    var.platform_helm_values_object,
    {
      for group in var.platform_node_group == null ? [] : [var.platform_node_group] :
      "platformNodeSelector" => { "kube-compute.io/node-group" = group }
    },
  )

  autoscaled_instance_types = distinct(flatten([for role in var.autoscaled_nodes : role.instance_types]))

  fixed_cpu_cores = sum(concat(
    [var.control_plane_count * data.aws_ec2_instance_type.sized[var.instance_type].default_vcpus],
    [for group in var.static_nodes : group.node_count * data.aws_ec2_instance_type.sized[group.instance_type].default_vcpus],
  ))

  fixed_memory_mib = sum(concat(
    [var.control_plane_count * data.aws_ec2_instance_type.sized[var.instance_type].memory_size],
    [for group in var.static_nodes : group.node_count * data.aws_ec2_instance_type.sized[group.instance_type].memory_size],
  ))

  # How many of each instance type fit its role's caps on their own.
  autoscaled_max_sizes = {
    for role, config in var.autoscaled_nodes : role => {
      for type in config.instance_types : type => floor(min(
        config.max_cpu_cores / data.aws_ec2_instance_type.sized[type].default_vcpus,
        config.max_memory_gib * 1024 / data.aws_ec2_instance_type.sized[type].memory_size,
      ))
    }
  }

  autoscaled_cpu_cores  = sum(concat([0], [for config in var.autoscaled_nodes : config.max_cpu_cores]))
  autoscaled_memory_gib = sum(concat([0], [for config in var.autoscaled_nodes : config.max_memory_gib]))

  autoscaling_group_arns = flatten([for role in module.autoscaled_nodes : [for group in values(role.autoscaling_groups) : group.arn]])

  platform_extra_helm_parameters = merge(
    var.platform_extra_helm_parameters,
    local.autoscaling_enabled ? {
      clusterAutoscalerEnabled       = "true"
      clusterAutoscalerCloudProvider = "aws"
      awsRegion                      = var.aws_region
      clusterAutoscalerCoresTotal    = "0:${local.fixed_cpu_cores + local.autoscaled_cpu_cores}"
      clusterAutoscalerMemoryTotal   = "0:${ceil(local.fixed_memory_mib / 1024) + local.autoscaled_memory_gib}"
    } : {},
  )
}

module "control_plane" {
  source = "./modules/control-plane"

  cluster_name                      = var.cluster_name
  trusted_ca_pem                    = var.trusted_ca_pem
  trusted_ca_in_image               = var.trusted_ca_in_image
  registry_mirror_url               = var.registry_mirror_url
  dns_servers                       = var.dns_servers
  gitops_platform_enabled           = var.gitops_platform_enabled
  gitops_platform_repo_url_override = var.gitops_platform_repo_url_override
  gitops_platform_revision_override = var.gitops_platform_revision_override
  gitops_workloads_repo_url         = var.gitops_workloads_repo_url
  gitops_workloads_revision         = var.gitops_workloads_revision
  gitops_workloads_path             = var.gitops_workloads_path
  workloads_extra_helm_parameters   = var.workloads_extra_helm_parameters
  workloads_helm_values_object      = var.workloads_helm_values_object
  cluster_type                      = var.cluster_type
  cni                               = var.cni
  cert_mode                         = var.cert_mode
  platform_extra_helm_parameters    = local.platform_extra_helm_parameters
  platform_helm_values_object       = local.platform_helm_values_object
  extra_tags                        = var.extra_tags
  aws_region                        = var.aws_region
  control_plane_count               = var.control_plane_count
  control_plane_subnets             = var.control_plane_subnets
  endpoint_mode                     = var.endpoint_mode
  static_registration_address       = var.static_registration_address
  subnet_id                         = var.subnet_id
  vpc_name                          = var.vpc_name
  subnet_name                       = var.subnet_name
  subnet_names                      = var.subnet_names
  subnet_min_free_ips               = local.launch_ip_count
  cluster_domain                    = var.cluster_domain
  manage_wildcard_dns_record        = var.platform_node_group == null
  hosted_zone_name                  = var.hosted_zone_name
  hosted_zone_id                    = var.hosted_zone_id
  instance_type                     = var.instance_type
  os_image_ami_id                   = var.os_image_ami_id
  os_image_name                     = var.os_image_name
  allowed_ingress_cidrs             = var.allowed_ingress_cidrs
  ingress_ports                     = var.ingress_ports
  root_volume_size_gb               = var.root_volume_size_gb
  root_volume_type                  = var.root_volume_type
  aws_provider_id                   = local.autoscaling_enabled
}

# See modules/aws-static-node/README.md for why named instances suit fixed roles.
module "static_nodes" {
  source   = "./modules/static-node"
  for_each = var.static_nodes

  cluster_name              = var.cluster_name
  group_name                = each.key
  aws_region                = var.aws_region
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_fqdn_suffix       = var.cluster_domain != null ? "${var.cluster_name}.${var.cluster_domain}" : null
  aws_provider_id           = local.autoscaling_enabled

  # Ingress runs with the platform, so only the platform group answers on the external ports.
  security_group_ids = concat(
    [module.control_plane.cluster_security_group_id],
    each.key == var.platform_node_group ? [module.control_plane.node_security_group_id] : [],
  )

  # Defaults to the control plane's own subnet, so a group inherits its availability zone.
  # An EBS volume cannot cross zones, so a worker in another one cannot mount its data.
  subnet_id             = coalesce(each.value.subnet_id, module.control_plane.subnet_id)
  node_count            = each.value.node_count
  instance_type         = each.value.instance_type
  os_image_ami_id       = each.value.os_image_ami_id
  os_image_name         = each.value.os_image_name != null ? each.value.os_image_name : var.os_image_name
  root_volume_size_gb   = each.value.root_volume_size_gb
  root_volume_type      = each.value.root_volume_type
  node_labels           = each.value.node_labels
  node_taints           = each.value.node_taints
  attach_ebs_csi_policy = each.value.attach_ebs_csi_policy

  # Cluster-wide by default, overridable per group. A ternary rather than coalesce(): all
  # three are commonly null on both sides, and coalesce raises when every argument is null.
  trusted_ca_pem      = each.value.trusted_ca_pem != null ? each.value.trusted_ca_pem : var.trusted_ca_pem
  trusted_ca_in_image = var.trusted_ca_in_image
  registry_mirror_url = each.value.registry_mirror_url != null ? each.value.registry_mirror_url : var.registry_mirror_url
  dns_servers         = each.value.dns_servers != null ? each.value.dns_servers : var.dns_servers
  extra_tags          = merge(var.extra_tags, each.value.extra_tags)
}

module "autoscaled_nodes" {
  source   = "./modules/node-pool"
  for_each = var.autoscaled_nodes

  cluster_name              = var.cluster_name
  group_name                = each.key
  aws_region                = var.aws_region
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_security_group_id = module.control_plane.cluster_security_group_id
  subnet_id                 = module.control_plane.subnet_id

  # At least one, so an instance type too large for its role's caps fails on
  # terraform_data.autoscaling_limits instead of inside this module.
  instance_type_max_sizes = { for type, max_size in local.autoscaled_max_sizes[each.key] : type => max(1, max_size) }

  os_image_ami_id     = each.value.os_image_ami_id
  os_image_name       = var.os_image_name
  root_volume_size_gb = each.value.root_volume_size_gb
  root_volume_type    = each.value.root_volume_type
  node_labels         = each.value.node_labels
  node_taints         = each.value.node_taints

  trusted_ca_pem      = var.trusted_ca_pem
  trusted_ca_in_image = var.trusted_ca_in_image
  registry_mirror_url = var.registry_mirror_url
  dns_servers         = var.dns_servers
  extra_tags          = var.extra_tags
}

resource "terraform_data" "autoscaling_limits" {
  count = local.autoscaling_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = alltrue(flatten([for sizes in values(local.autoscaled_max_sizes) : [for max_size in values(sizes) : max_size >= 1]]))
      error_message = "Instance types larger than their role's max_cpu_cores or max_memory_gib could never be launched: ${join(", ", flatten([for role, sizes in local.autoscaled_max_sizes : [for type, max_size in sizes : "${role} ${type}" if max_size < 1]]))}."
    }
  }
}

# The platform's controllers authenticate as the node they run on.
resource "aws_iam_role_policy" "autoscaling" {
  count = local.autoscaling_enabled ? 1 : 0
  name  = "kube-compute-${var.cluster_name}-autoscaling"
  role  = local.platform_node_iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ClusterAutoscalerDiscovery"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
        ]
        Resource = "*"
      },
      {
        Sid      = "ClusterAutoscalerScaling"
        Effect   = "Allow"
        Action   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
        Resource = local.autoscaling_group_arns
      },
    ]
  })
}

# The cloud controller manager runs on the control plane.
resource "aws_iam_role_policy" "cloud_controller_manager" {
  count = local.autoscaling_enabled ? 1 : 0
  name  = "kube-compute-${var.cluster_name}-cloud-controller-manager"
  role  = module.control_plane.node_iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "NodeLifecycle"
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
      ]
      Resource = "*"
    }]
  })
}

# The control plane's own wildcard record is off whenever this one exists.
resource "aws_route53_record" "platform_wildcard" {
  count   = var.platform_node_group != null && module.control_plane.wildcard_dns_name != null && module.control_plane.hosted_zone_id != null ? 1 : 0
  zone_id = module.control_plane.hosted_zone_id
  name    = module.control_plane.wildcard_dns_name
  type    = "A"
  ttl     = 60
  records = values(module.static_nodes[var.platform_node_group].private_ips)
}
