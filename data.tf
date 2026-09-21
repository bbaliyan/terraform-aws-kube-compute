# SPDX-License-Identifier: Apache-2.0
# Deliberately not named "current". A consumer's terragrunt generate blocks land
# .tf files in this same module directory, and "current" is the name anyone would
# pick for this -- kube-clusters' own iam-eso include already uses it, and two
# declarations of one name is a hard init failure for every cluster.
data "aws_caller_identity" "kube_compute" {}

data "aws_ec2_instance_type" "sized" {
  for_each      = toset(concat([var.instance_type], [for group in var.static_nodes : group.instance_type], local.autoscaled_instance_types))
  instance_type = each.key
}
