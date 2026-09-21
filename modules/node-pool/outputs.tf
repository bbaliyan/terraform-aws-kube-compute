# SPDX-License-Identifier: Apache-2.0
output "autoscaling_groups" {
  description = "Map of instance type -> {name, arn, max_size, node_arch}, one Auto Scaling group per type. Their instances are invisible to Terraform; find them through the group."
  value = {
    for type, group in aws_autoscaling_group.node : type => {
      name      = group.name
      arn       = group.arn
      max_size  = group.max_size
      node_arch = local.ami_arch[type]
    }
  }
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "subnet_id" {
  description = "Subnet every group launches into."
  value       = var.subnet_id
}

output "availability_zone" {
  description = "Availability zone of subnet_id."
  value       = local.availability_zone
}

output "node_iam_role_name" {
  description = "IAM role attached to every node of this role."
  value       = aws_iam_role.node.name
}

output "node_labels" {
  description = "Labels every node of this role carries. Each node also carries node.kubernetes.io/instance-type."
  value       = local.node_labels
}

output "node_taints" {
  description = "Taints every node of this role carries."
  value       = var.node_taints
}
