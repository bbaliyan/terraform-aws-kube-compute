# SPDX-License-Identifier: Apache-2.0

output "cluster_name" {
  description = "Cluster name passed to the module."
  value       = module.control_plane.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID of the genesis control-plane instance."
  value       = module.control_plane.instance_id
}

output "cluster_ip" {
  description = "Genesis control-plane node's private IP."
  value       = module.control_plane.cluster_ip
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given."
  value       = module.control_plane.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier ('aws')."
  value       = module.control_plane.node_provider
}

output "node_control_ref" {
  description = "Genesis instance ID, for control-plane verb-scripts that need a single node reference (SSM send-command/start-session)."
  value       = module.control_plane.node_control_ref
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services, or null when no cluster_domain was given."
  value       = module.control_plane.wildcard_dns_name
}

output "aws_region" {
  description = "Region the cluster runs in (the verb-scripts need it for SSM calls)."
  value       = module.control_plane.aws_region
}

output "node_arch" {
  description = "CPU architecture reported by AWS for instance_type."
  value       = module.control_plane.node_arch
}

output "effective_ami_id" {
  description = "AMI ID actually used for the control-plane node(s) (explicit os_image_ami_id, an os_image_name lookup, or the AlmaLinux 10 data-lookup fallback)."
  value       = module.control_plane.effective_ami_id
}

output "vpc_id" {
  description = "VPC ID the control plane launched into."
  value       = module.control_plane.vpc_id
}

output "subnet_id" {
  description = "Subnet ID the genesis control-plane node launched into."
  value       = module.control_plane.subnet_id
}

output "node_iam_role_name" {
  description = "IAM role name attached to the control-plane node(s). Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO)."
  value       = module.control_plane.node_iam_role_name
}

output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API."
  value       = module.control_plane.registration_address
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, provider}."
  value       = module.control_plane.control_plane_node_refs
}

output "cluster_security_group_id" {
  description = "Self-referencing security group id shared by every cluster member."
  value       = module.control_plane.cluster_security_group_id
}

output "agent_token_ssm_parameter" {
  description = "SSM Parameter Store name (SecureString) holding the agent join token."
  value       = module.control_plane.agent_token_ssm_parameter
}

output "static_nodes" {
  description = "Map of group name -> {node_provider, node_refs, instance_ids, private_ips, availability_zone, node_arch, node_iam_role_name, node_labels, node_taints}."
  value = {
    for name, group in module.static_nodes : name => {
      node_provider      = group.node_provider
      node_refs          = group.node_refs
      instance_ids       = group.instance_ids
      private_ips        = group.private_ips
      availability_zone  = group.availability_zone
      node_arch          = group.node_arch
      node_iam_role_name = group.node_iam_role_name
      node_labels        = group.node_labels
      node_taints        = group.node_taints
    }
  }
}

output "all_instance_ids" {
  description = "Every EC2 instance Terraform owns individually: the control-plane node(s) plus every static node. Excludes autoscaled nodes, which can be removed but not stopped."
  value       = local.all_instance_ids
}

output "platform_node_iam_role_name" {
  description = "IAM role of the nodes running the platform stack: platform_node_group's, or the control plane's when none is set. Policies for platform controllers that authenticate as their node, such as External Secrets, belong on it."
  value       = local.platform_node_iam_role_name
}

output "workload_node_iam_role_names" {
  description = "IAM roles of every node a workload pod can be scheduled on. Policies a workload authenticates with through its node belong on each of them."
  value       = local.workload_node_iam_role_names
}

output "autoscaled_nodes" {
  description = "Map of role -> {autoscaling_groups, availability_zone, node_iam_role_name, node_labels, node_taints}, where autoscaling_groups maps each instance type to its group's {name, arn, max_size, node_arch}."
  value = {
    for name, role in module.autoscaled_nodes : name => {
      autoscaling_groups = role.autoscaling_groups
      availability_zone  = role.availability_zone
      node_iam_role_name = role.node_iam_role_name
      node_labels        = role.node_labels
      node_taints        = role.node_taints
    }
  }
}

output "cluster_autoscaler_limits" {
  description = "The cluster-wide totals passed to cluster-autoscaler: every role's max_cpu_cores and max_memory_gib plus the control plane and static nodes. Null without autoscaled_nodes."
  value = local.autoscaling_enabled ? {
    cores_total  = local.platform_extra_helm_parameters.clusterAutoscalerCoresTotal
    memory_total = local.platform_extra_helm_parameters.clusterAutoscalerMemoryTotal
  } : null
}

output "hosted_zone_id" {
  description = "Route53 zone the cluster's records live in, or null when no domain is configured."
  value       = module.control_plane.hosted_zone_id
}
