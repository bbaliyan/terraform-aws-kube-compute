# SPDX-License-Identifier: Apache-2.0
output "cloud_init_user_data" {
  description = "Complete '#cloud-config' document for this node: hostname, base64 write_files payloads (RKE2 config, registries, CA, manifests) and a runcmd that runs the bootstrap script. Deliver it verbatim as user data. Sensitive: it carries the join tokens and the CA."
  value       = local.cloud_init_user_data
  sensitive   = true

  precondition {
    condition     = !local.platform_clone_needed || local.boot_platform_repo_url != ""
    error_message = "gitops_platform_repo_url is required on the first server when gitops_platform_enabled is false and the node still needs Cilium or Argo CD: the first server clones that repo for bootstrap/rendered/. Set it to the platform repo."
  }
}

output "node_name" {
  description = "Node name this payload was rendered for — the OS hostname it sets, and therefore the Kubernetes node name RKE2/kubelet will register. Echoed back so a caller can key snippet filenames off the same value without recomputing it."
  value       = var.node_name
}

output "boot_steps" {
  description = "Every step of this node's boot, in the order it runs: the provider steps, the module's cloud-init commands, the steps of the boot program, then the commands that follow it. The names say what the node does, so a test can assert the exact list."
  value       = local.boot_steps
}
