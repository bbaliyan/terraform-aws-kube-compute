# SPDX-License-Identifier: Apache-2.0

output "node_refs" {
  description = "Map of Kubernetes node name -> {instance_id, provider}. Same shape as aws-control-plane's control_plane_node_refs, so anything already targeting control-plane nodes takes workers without a second code path. An ASG cannot produce this."
  value = {
    for k, inst in aws_instance.node :
    local.node_names[k] => {
      instance_id = inst.id
      provider    = "aws"
    }
  }
}

output "instance_ids" {
  description = "This group's EC2 instance ids. A stop schedule scopes its IAM policy to instance ARNs, so it needs ids that survive a reboot."
  value       = [for k in sort(keys(aws_instance.node)) : aws_instance.node[k].id]
}

output "private_ips" {
  description = "Map of Kubernetes node name -> private IP."
  value       = { for k, inst in aws_instance.node : local.node_names[k] => inst.private_ip }
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "availability_zone" {
  description = "Availability zone this group is pinned to, derived from subnet_id."
  value       = local.availability_zone
}

output "node_arch" {
  description = "CPU architecture AWS reports for instance_type, and what the AMI lookup filtered on."
  value       = local.ami_arch
}

output "effective_ami_id" {
  description = "AMI ID actually used."
  value       = local.effective_ami_id
}

output "node_iam_role_name" {
  description = "IAM role name attached to every node in this group. Reference it to attach additional policies."
  value       = aws_iam_role.node.name
}

output "node_labels" {
  description = "Every label applied at rke2 install time, including the two this module sets itself. Exposed so a consumer builds a nodeSelector from it rather than restating it."
  value       = local.node_labels
}

output "node_taints" {
  description = "The taints applied at rke2 install time. Exposed so a consumer builds tolerations from them rather than restating them."
  value       = var.node_taints
}

output "subnet_id" {
  description = "Subnet every node launched into. Exposed so a composing module can assert the group inherited the control plane's subnet rather than drifting into another zone."
  value       = var.subnet_id
}
