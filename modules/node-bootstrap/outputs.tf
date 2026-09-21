# SPDX-License-Identifier: Apache-2.0
output "cloud_init_user_data" {
  description = "Complete '#cloud-config' document for this one node: hostname, the RKE2 config/registries/CA/manifest payloads as base64 write_files, and a runcmd invoking the bootstrap script. The caller delivers it verbatim as its provider's user-data (on Proxmox, a proxmox_virtual_environment_file snippet wired to initialization.user_data_file_id). This module executes nothing itself — there is no bootstrap resource to depend on; a caller needing ordering must depend on its own VM resource instead. Sensitive: carries the join tokens, trusted CA, and TSIG secret."
  value       = local.cloud_init_user_data
  sensitive   = true

  precondition {
    condition     = strcontains(local.bootstrap_program, "BOOTSTRAP_CONTRACT=${local.node_env_contract}")
    error_message = "files/bootstrap.sh declares a different bootstrap contract than node_env_contract in main.tf. They are the two halves of one agreement -- the program refuses to run against a node.env written for another contract -- so bump them together."
  }
}

output "node_name" {
  description = "Node name this payload was rendered for — the OS hostname it sets, and therefore the Kubernetes node name RKE2/kubelet will register. Echoed back so a caller can key snippet filenames off the same value without recomputing it."
  value       = var.node_name
}
