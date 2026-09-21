# SPDX-License-Identifier: Apache-2.0

# ---- Standardized outputs (identical names across all provider modules) ----

output "cluster_name" {
  description = "Cluster name passed to the module. Use this to name local kubeconfig files and other client-side resources."
  value       = var.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID."
  value       = aws_instance.control_plane.id
}

output "cluster_ip" {
  description = "Private IP of the RKE2 node. Register your DNS wildcard at this address."
  value       = aws_instance.control_plane.private_ip
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given (IP-only)."
  value       = local.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "node_control_ref" {
  description = "Handle the control-plane verb-scripts use to reach the node out-of-band (kubeconfig fetch, break-glass shell). For AWS: the instance ID, targeted via 'aws ssm send-command'/'aws ssm start-session' in region aws_region. Renamed from bootstrap_status_ref: no status file exists to reference anymore now that cloud-init (not Ansible) owns bootstrap, and this was always really just a node-addressing handle."
  value       = aws_instance.control_plane.id
}

# ---- DNS support: register this yourself if you didn't pass a hosted_zone_id ----
output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services (e.g. *.bharat.example.internal), or null when no cluster_domain was given. Point this at cluster_ip in your DNS of choice."
  value       = local.wildcard_name
}

# ---- Useful AWS extras ----
output "aws_region" {
  description = "Region the node runs in (the verb-scripts need it for SSM calls)."
  value       = var.aws_region
}

output "node_arch" {
  description = "CPU architecture reported by AWS for the instance type (arm64 or x86_64)."
  value       = local.ami_arch
}

output "effective_ami_id" {
  description = "AMI ID used (explicit override or AlmaLinux 10 lookup)."
  value       = local.effective_ami_id
}

output "vpc_id" {
  description = "VPC ID the control plane launched into (derived from the subnet — the single-node subnet_id/subnet_name/default-VPC fallback for control_plane_count = 1, or the control-plane subnets themselves for control_plane_count > 1)."
  value       = local.module_vpc_id
}

output "subnet_id" {
  description = "Subnet ID the genesis node launched into; the first control-plane AZ slot when control_plane_count > 1, and identical to the single-node resolution below that. Consumed by aws-static-node so a worker inherits the control plane's availability zone."
  value       = local.genesis_subnet_id
}

output "node_security_group_id" {
  description = "Security group carrying this cluster's external ingress_ports rules. A worker that takes over the ingress controller needs it, or the ports stay open on a node no longer serving them. Distinct from cluster_security_group_id, which is east-west only."
  value       = aws_security_group.node.id
}

output "node_iam_role_name" {
  description = "IAM role name attached to the node. Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO)."
  value       = aws_iam_role.node.name
}

# ---- Join flow: consumed by aws-node-pool (and, later, additional control-plane nodes) ----
output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API. For control_plane_count = 1, this is the sole control-plane node's private IP. For control_plane_count > 1, it depends on endpoint_mode: the internal NLB's DNS name (loadbalancer, default), the shared Route53 record name (dns), or static_registration_address verbatim (static)."
  value       = local.registration_address != null ? local.registration_address : aws_instance.control_plane.private_ip
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, provider}. The control-plane abstraction (SSM send-command today) targets every node from this map instead of a single node_control_ref."
  value = merge(
    {
      "cp-${var.cluster_name}-1" = {
        instance_id = aws_instance.control_plane.id
        provider    = "aws"
      }
    },
    {
      for i, inst in aws_instance.control_plane_additional :
      "cp-${var.cluster_name}-${tonumber(i) + 1}" => {
        instance_id = inst.id
        provider    = "aws"
      }
    }
  )
}

output "cluster_security_group_id" {
  description = "Self-referencing security group id shared by every cluster member. This module's own instances attach to it by id; a future aws-node-pool unit would depend on this module to attach its workers the same way."
  value       = aws_security_group.cluster.id
}

output "agent_token_ssm_parameter" {
  description = "SSM Parameter Store name (SecureString) holding the agent join token. A future aws-node-pool unit's workers would fetch it at boot via their own instance IAM role — never embedded in user_data."
  value       = aws_ssm_parameter.agent_token.name
}

output "connectivity_user_data_base64" {
  description = "base64gzip of the genesis node's combined user-data (the AWS-only SSM-agent-enable script MIME-multipart-joined with node-bootstrap's #cloud-config payload). Exposed for tests and debugging."
  value       = base64gzip(local.combined_user_data["0"])
  sensitive   = true
}

output "hosted_zone_id" {
  description = "Route53 zone the cluster's records live in, resolved from hosted_zone_id or hosted_zone_name. Null when no domain is configured."
  value       = local.effective_zone_id
}
