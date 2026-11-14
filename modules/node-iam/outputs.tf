# SPDX-License-Identifier: Apache-2.0

output "role_name" {
  description = "Name of the node IAM role."
  value       = aws_iam_role.node.name
}

output "instance_profile_name" {
  description = "Name of the node instance profile."
  value       = aws_iam_instance_profile.node.name
}
