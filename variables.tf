# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter or digit."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter or digit, max 31 chars."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "trusted_ca_in_image" {
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. If true, user data omits the PEM, but the value is still used for the containerd TLS pin. The boot program fails if the file is missing."
  type        = bool
  default     = false
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs. They give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record. Null keeps the kubelet default. 169.254.169.253 is the Amazon-provided resolver."
  type        = list(string)
  default     = null
}

variable "gitops_platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application."
  type        = bool
  default     = true
}

variable "gitops_platform_repo_url_override" {
  description = "Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin."
  type        = string
  default     = null
}

variable "gitops_platform_revision_override" {
  description = "Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application."
  type        = string
  default     = null
}

variable "gitops_workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops_workloads_repo_url is set."
  type        = string
  default     = "main"
}

variable "gitops_workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when gitops_workloads_repo_url is set."
  type        = string
  default     = "."
}

variable "cluster_type" {
  description = "Cluster topology intent: 'all_in_one' (control-plane nodes stay schedulable) or 'dedicated_control_plane' (control-plane nodes are tainted so user workloads run only on separate node pools)."
  type        = string
  default     = "all_in_one"
  validation {
    condition     = contains(["all_in_one", "dedicated_control_plane"], var.cluster_type)
    error_message = "cluster_type must be 'all_in_one' or 'dedicated_control_plane'."
  }
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. 'selfsigned' (default), 'byo', or 'acme'."
  type        = string
  default     = "selfsigned"
  validation {
    condition     = contains(["selfsigned", "byo", "acme"], var.cert_mode)
    error_message = "cert_mode must be 'selfsigned', 'byo', or 'acme'."
  }
}

variable "platform_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application."
  type        = map(string)
  default     = {}
}

variable "workloads_extra_helm_parameters" {
  description = "Helm parameters forwarded verbatim to the workloads Application. See node-bootstrap for full description."
  type        = map(string)
  default     = {}
}

variable "workloads_helm_values_object" {
  description = "Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations."
  type        = any
  default     = null
}

variable "platform_helm_values_object" {
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags applied to every AWS resource this module creates (EC2 instance, root EBS volume, security group, IAM role), and forwarded to node-bootstrap so platform-managed resources (e.g. CSI-provisioned storage) can tag themselves consistently."
  type        = map(string)
  default     = {}
}

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region the cluster runs in. Exposed as an output so the SSM control-plane scripts (and node pools) know which region to target. Does NOT configure the provider — the caller sets the provider region; pass the same value here."
  type        = string
}

variable "control_plane_count" {
  description = "Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3, or 5."
  }
}

variable "control_plane_subnets" {
  description = "Map of availability zone -> subnet id for control-plane placement, required when control_plane_count > 1. Ignored when control_plane_count = 1 — use subnet_id/subnet_name instead."
  type        = map(string)
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || var.control_plane_subnets != null
    error_message = "control_plane_subnets is required when control_plane_count > 1."
  }
}

variable "endpoint_mode" {
  description = "How joining nodes reach the registration endpoint once control_plane_count > 1 (ignored for control_plane_count = 1): \"loadbalancer\" (default) creates an internal NLB; \"dns\" creates Route53 multivalue-answer A records; \"static\" uses static_registration_address verbatim."
  type        = string
  default     = "loadbalancer"
  validation {
    condition     = contains(["loadbalancer", "dns", "static"], var.endpoint_mode)
    error_message = "endpoint_mode must be one of: loadbalancer, dns, static."
  }
}

variable "static_registration_address" {
  description = "Consumer-supplied registration endpoint address, used verbatim as registration_address when endpoint_mode = \"static\". Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.endpoint_mode != "static" || var.static_registration_address != null
    error_message = "static_registration_address is required when endpoint_mode = \"static\"."
  }
}

# Networking: the module takes a network HANDLE and never creates fabric (VPC/subnet/IGW/NAT).
variable "subnet_id" {
  description = "Subnet the control-plane node (control_plane_count = 1) launches into. Null = the module falls back to a subnet in the account's default VPC."
  type        = string
  default     = null
}

variable "vpc_name" {
  description = "Name tag of the VPC. Pair with subnet_name to scope the subnet lookup to a specific VPC. Ignored when subnet_id is used."
  type        = string
  default     = null
}

variable "subnet_names" {
  description = "Candidate subnets by Name tag, in order of preference. The first with a free address for the control plane and each static node without its own subnet_id wins, and the choice stays in state. To choose again, replace terraform_data.subnet_choice[0] in the control plane. List form of subnet_name."
  type        = list(string)
  default     = null
}

variable "subnet_name" {
  description = "Name tag of the subnet to launch the control-plane node into (control_plane_count = 1 only). Alternative to subnet_id."
  type        = string
  default     = null
}

variable "cluster_domain" {
  description = "Optional DNS suffix for the cluster, e.g. 'example.internal'. When set, the FQDN is <cluster_name>.<cluster_domain> and the wildcard is *.<cluster_name>.<cluster_domain>. Null = node is reachable by IP only."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Name of the Route53 private hosted zone. Alternative to hosted_zone_id. Requires cluster_domain to be set."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID. Alternative to hosted_zone_name. Requires cluster_domain to be set. Null = create no record; register DNS yourself using the wildcard_dns_name output."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type (bundles vCPU + memory) for the control-plane node(s). CPU arch (arm64/x86_64) is derived from the family prefix for AMI selection."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = "AMI ID of a kube-images build for the control-plane node(s). Set this or os_image_name. The image must have RKE2 baked in, and no check compares the AMI with what is baked in it."
  type        = string
  default     = null
}

variable "os_image_name" {
  description = "AMI name of a kube-images build for the control-plane nodes. Set this or os_image_ami_id, which wins if set. Accepts EC2 Name wildcards (*, ?); a pattern without the build date picks the newest match."
  type        = string
  default     = null

  validation {
    condition     = var.os_image_ami_id != null || var.os_image_name != null
    error_message = "Set os_image_ami_id or os_image_name to a kube-images AMI. A stock image has no RKE2, so the node would never join."
  }
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports from outside the cluster — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
}

variable "ingress_ports" {
  description = "TCP ports opened on the control-plane security group: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH)."
  type        = list(number)
  default     = [80, 443, 6443]
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB) for the control-plane node(s). Covers OS + container image cache."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...) for the control-plane node(s)."
  type        = string
  default     = "gp3"
}

variable "static_nodes" {
  description = "Named worker node groups keyed by group name (e.g. 'platform'), each created through aws-static-node with the cluster's identity, join address and security groups. For capacity the cluster must always have. subnet_id defaults to the control plane's. Empty (the default) creates none."
  type = map(object({
    node_count            = optional(number, 1)
    instance_type         = optional(string, "m7g.medium")
    subnet_id             = optional(string)
    os_image_ami_id       = optional(string)
    os_image_name         = optional(string)
    root_volume_size_gb   = optional(number, 20)
    root_volume_type      = optional(string, "gp3")
    node_labels           = optional(map(string), {})
    node_taints           = optional(list(string), [])
    attach_ebs_csi_policy = optional(bool, true)
    trusted_ca_pem        = optional(string)
    registry_mirror_url   = optional(string)
    dns_servers           = optional(list(string))
    extra_tags            = optional(map(string), {})
    node_name_template    = optional(string)
  }))
  default = {}

  validation {
    condition     = length(compact([for group in values(var.static_nodes) : group.node_name_template])) == length(distinct(compact([for group in values(var.static_nodes) : group.node_name_template])))
    error_message = "Two static_nodes groups have the same node_name_template, so their nodes would share names."
  }
}

variable "platform_node_group" {
  description = "static_nodes key of the group that runs the platform stack, ingress included. That group's node-group label pins the platform components, it alone takes the ingress security group, and the wildcard DNS record points at it. Null keeps all of that on the control plane."
  type        = string
  default     = null

  validation {
    condition     = var.platform_node_group == null ? true : contains(keys(var.static_nodes), var.platform_node_group)
    error_message = "platform_node_group must name a static_nodes group."
  }
}

variable "power_schedule" {
  description = "When nodes run. days uses EventBridge Scheduler form (MON-FRI); unset means every day. At stop_time the control plane and static nodes stop and autoscaled groups scale to zero. start_time starts them again; without it the cluster stays stopped. Times are HH:MM in timezone. Null: always running."
  type = object({
    stop_time  = string
    timezone   = string
    start_time = optional(string)
    days       = optional(string)
  })
  default = null

  validation {
    condition     = var.power_schedule == null ? true : can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.power_schedule.stop_time))
    error_message = "power_schedule.stop_time must be HH:MM on a 24-hour clock."
  }

  validation {
    condition     = try(var.power_schedule.start_time, null) == null ? true : can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.power_schedule.start_time))
    error_message = "power_schedule.start_time must be HH:MM on a 24-hour clock."
  }

  validation {
    condition     = try(var.power_schedule.start_time, null) == null || try(var.power_schedule.start_time != var.power_schedule.stop_time, true)
    error_message = "power_schedule.start_time must differ from stop_time."
  }

  validation {
    condition     = try(var.power_schedule.days, null) == null ? true : can(regex("^(SUN|MON|TUE|WED|THU|FRI|SAT)(-(SUN|MON|TUE|WED|THU|FRI|SAT))?(,(SUN|MON|TUE|WED|THU|FRI|SAT)(-(SUN|MON|TUE|WED|THU|FRI|SAT))?)*$", var.power_schedule.days))
    error_message = "power_schedule.days must be days of the week such as MON-FRI or MON,WED,FRI."
  }
}

variable "autoscaled_nodes" {
  description = "Roles the autoscaler fills. Each instance type is an Auto Scaling group from zero in the control-plane subnet, labelled kube-compute.io/node-group=<role>. max_cpu_cores and max_memory_gib cap a role. Adding the first role or removing the last replaces the control plane and static nodes."
  type = map(object({
    instance_types      = list(string)
    max_cpu_cores       = number
    max_memory_gib      = number
    os_image_ami_id     = optional(string)
    root_volume_size_gb = optional(number, 20)
    root_volume_type    = optional(string, "gp3")
    node_labels         = optional(map(string), {})
    node_taints         = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for role in var.autoscaled_nodes : length(role.instance_types) > 0 && length(distinct(role.instance_types)) == length(role.instance_types)])
    error_message = "every autoscaled role needs at least one instance type, each listed once."
  }

  validation {
    condition     = alltrue([for role in var.autoscaled_nodes : role.max_cpu_cores >= 1 && role.max_memory_gib >= 1])
    error_message = "every autoscaled role needs max_cpu_cores and max_memory_gib of at least 1."
  }

  validation {
    condition     = length(var.autoscaled_nodes) == 0 || var.gitops_platform_enabled
    error_message = "autoscaled_nodes requires gitops_platform_enabled: cluster-autoscaler is installed by the platform Application."
  }
}

variable "orphan_volume_cleanup" {
  description = "Delete the cluster's dynamically provisioned EBS volumes on destroy, found by their ClusterName tag. Turn it off where a volume must outlive the cluster, for example a Retain PersistentVolume. With it off, a destroy keeps every data volume."
  type        = bool
  default     = true
}

variable "graceful_shutdown" {
  description = "How long kubelet delays an OS shutdown to evict pods. critical_seconds is the part reserved for critical pods and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables it. Keep the total well under 2 minutes."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}
}

variable "os_auto_updates" {
  description = "Install OS updates with dnf-automatic on every node, daily, without rebooting. RKE2 packages are excluded, because system-upgrade-controller upgrades them. needs-restarting (yum-utils) reports a due reboot. False leaves packages as baked."
  type        = bool
  default     = true
}

variable "control_plane_node_name_template" {
  description = "Name for each control-plane node: hostname, Kubernetes node name and Name tag. {zone} is the last letter of the availability zone. {number} is the node number as two digits. Null keeps cp-<cluster_name>-<n>."
  type        = string
  default     = null
}

