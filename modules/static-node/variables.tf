# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
variable "cluster_name" {
  description = "Cluster identity these nodes join. Must match the control plane's cluster_name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "group_name" {
  description = "Names a role, not a machine: \"platform\", \"dedicated\", \"build\". Used in each instance and Kubernetes node name (<cluster_name>-<group_name>-<n>), the IAM role, and the automatic kube-compute.io/node-group label."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.group_name))
    error_message = "group_name must be lowercase alphanumeric/hyphens, start with a letter, max 21 chars."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to each node's OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "trusted_ca_in_image" {
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. Passed through to node-bootstrap, which then keeps the PEM out of user data while still using its value for containerd's TLS pin. It is a property of the image, so it applies to every node booting from it."
  type        = bool
  default     = false
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror. Null = pull from upstream."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs, passed to node-bootstrap for a search-domain-free kubelet resolv-conf. Pass the same value the control plane got: a wildcard cluster DNS record poisons every node's pods identically."
  type        = list(string)
  default     = null
}

variable "cluster_fqdn_suffix" {
  description = "The control plane's fqdn_suffix, used only to give each node a matching cloud-init fqdn. Never the API server name."
  type        = string
  default     = null
}

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region these nodes run in. Must match the control plane's region."
  type        = string
}

variable "registration_address" {
  description = "The control plane's registration_address output. Nodes join via https://<this>:9345."
  type        = string
}

variable "agent_token_ssm_parameter" {
  description = "This cluster's aws-control-plane agent_token_ssm_parameter output. This module's IAM role is scoped to read only it."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to every node. The control plane's cluster_security_group_id at minimum; add its node_security_group_id for the group that runs the ingress controller, or the cluster's external ports keep answering on a node no longer serving them."
  type        = list(string)
  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "security_group_ids must contain at least the cluster security group -- a node with no group cannot reach the control plane to join."
  }
}

variable "subnet_id" {
  description = "Subnet every node launches into. Pass the control plane's own subnet_id output unless there is a deliberate reason not to: an EBS volume cannot cross availability zones, so a worker in another one cannot mount the data it was created for. This module never creates network fabric."
  type        = string
}

variable "node_count" {
  description = "How many named instances this group has."
  type        = number
  default     = 1
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 20
    error_message = "node_count must be between 1 and 20. Past that, use an autoscaled path instead."
  }
}

variable "instance_type" {
  description = "EC2 instance type for every node. CPU architecture is derived from AWS's own instance-type metadata, so an arm64 type resolves an arm64 image with no second input."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = "AMI ID. Tested with AlmaLinux 10 (RHEL-family). Null = latest AlmaLinux 10 for the derived architecture."
  type        = string
  default     = null
}

variable "os_image_name" {
  description = "AMI name, e.g. kube-image's build name. Resolved against this account's own AMIs and the derived architecture. Accepts EC2 Name-filter wildcards, so one pattern with a wildcard architecture segment serves both architectures. Ignored when os_image_ami_id is set."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB)."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...)."
  type        = string
  default     = "gp3"
}

variable "node_labels" {
  description = "Additional node-label: entries beyond the AZ and node-group labels this module always sets. Labels are what a workload selects a node by; keeping others off it is node_taints' job."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "node-taint: entries, each a full \"key=value:Effect\" string. Needs a matching toleration on the workload that belongs here, or nothing schedules at all."
  type        = list(string)
  default     = []
}

variable "attach_ebs_csi_policy" {
  description = "Attach AmazonEBSCSIDriverPolicy to this group's IAM role. On by default: the EBS CSI controller is an ordinary Deployment the scheduler can place on any node that tolerates its taints, so a group without the policy breaks volume provisioning whenever it lands there. Set false only for a group you have kept the controller off by taint."
  type        = bool
  default     = true
}

variable "aws_provider_id" {
  description = "Registers every node with providerID aws:///<zone>/<instance-id>. Needed on every node of a cluster whose nodes cluster-autoscaler and the AWS cloud controller manager look up by instance. Changing it replaces the nodes."
  type        = bool
  default     = false
}

variable "extra_tags" {
  description = "Additional tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "graceful_shutdown" {
  description = "How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}
}
