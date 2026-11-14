# SPDX-License-Identifier: Apache-2.0
output "steps" {
  description = "Value for node-bootstrap's provider_steps: a list of { name, commands } objects, one per enabled step."
  value       = local.steps
}
