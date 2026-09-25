# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Cluster identity this group joins. Must match the control plane's cluster_name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "group_name" {
  description = "Names the role these nodes play, e.g. \"workers\". Every node carries it as the kube-compute.io/node-group label, whatever its instance type."
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
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt, so it stays out of user data."
  type        = bool
  default     = false
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror. Null = pull from upstream."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs for a search-domain-free kubelet resolv-conf. Pass the same value the control plane got."
  type        = list(string)
  default     = null
}

variable "aws_region" {
  description = "AWS region the group runs in. Must match the control plane's region."
  type        = string
}

variable "registration_address" {
  description = "The control plane's registration_address output. Nodes join via https://<this>:9345."
  type        = string
}

variable "agent_token_ssm_parameter" {
  description = "The control plane's agent_token_ssm_parameter output. The group's IAM role can read only this parameter."
  type        = string
}

variable "cluster_security_group_id" {
  description = "The control plane's cluster_security_group_id output, for east-west traffic. Nodes in this group take no external traffic."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the group launches into. Pass the control plane's subnet_id output: an EBS volume cannot cross availability zones, so a node in another zone cannot mount the data it was created for."
  type        = string
}

variable "instance_type_max_sizes" {
  description = "Instance types this role launches, each with the most instances of that type cluster-autoscaler may run. Each type is its own Auto Scaling group, starting at zero: cluster-autoscaler requires every instance in a group to have the same shape."
  type        = map(number)
  validation {
    condition     = length(var.instance_type_max_sizes) > 0
    error_message = "instance_type_max_sizes needs at least one instance type."
  }
  validation {
    condition     = alltrue([for max_size in values(var.instance_type_max_sizes) : max_size >= 1])
    error_message = "every instance type needs a max size of at least 1."
  }
}

variable "os_image_ami_id" {
  description = "AMI ID for every instance type. Null = resolve os_image_name, or the latest AlmaLinux 10, for each instance type's architecture."
  type        = string
  default     = null
}

variable "os_image_name" {
  description = "AMI name, e.g. kube-image's build name, resolved against this account's own AMIs for each instance type's architecture. Accepts EC2 Name-filter wildcards. Ignored when os_image_ami_id is set."
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
  description = "Node labels beyond the zone, instance-type and node-group labels this module always sets."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Node taints, each \"key=value:Effect\". A pod needs a matching toleration to land here."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for t in var.node_taints : can(regex("^[^=:]+=[^=:]*:(NoSchedule|PreferNoSchedule|NoExecute)$", t))])
    error_message = "each node_taints entry must be key=value:Effect, where Effect is NoSchedule, PreferNoSchedule, or NoExecute."
  }
}

variable "extra_tags" {
  description = "Additional tags applied to every resource this module creates and every instance the groups launch."
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
