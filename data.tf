# SPDX-License-Identifier: Apache-2.0
# Deliberately not named "current". A consumer's terragrunt generate blocks land
# .tf files in this same module directory, and "current" is the name anyone would
# pick for this. Two declarations of one name is a hard init failure.
data "aws_caller_identity" "kube_compute" {}

data "aws_ec2_instance_type" "sized" {
  for_each      = toset(concat([var.instance_type], [for group in var.static_nodes : group.instance_type], local.autoscaled_instance_types))
  instance_type = each.key

  lifecycle {
    postcondition {
      condition     = alltrue([for role, config in var.autoscaled_nodes : floor(min(config.max_cpu_cores / self.default_vcpus, config.max_memory_gib * 1024 / self.memory_size)) >= 1 if contains(config.instance_types, each.key)])
      error_message = "Instance types larger than their role's max_cpu_cores or max_memory_gib could never be launched: ${join(", ", [for role, config in var.autoscaled_nodes : "${role} ${each.key}" if contains(config.instance_types, each.key) && floor(min(config.max_cpu_cores / self.default_vcpus, config.max_memory_gib * 1024 / self.memory_size)) < 1])}."
    }
  }
}
