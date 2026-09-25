# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "trusted_ca_in_image" {
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt, so no node in this cluster ships the PEM in its user data. The value is still used for containerd's TLS pin and the platform Application, and the bootstrap program fails the boot if the image does not carry the file."
  type        = bool
  default     = false
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs for the control plane, passed through to node-bootstrap to give kubelet a search-domain-free resolv-conf — defense in depth against any node-inherited DNS search domain colliding with a wildcard cluster DNS record (*.<cluster>.<domain>, see cluster_domain), on top of node-bootstrap's own prefer_fqdn_over_hostname fix for the specific hostname-derived case. Null/empty (the default) leaves kubelet's default ClusterFirst DNS policy in place: every pod inherits its node's own /etc/resolv.conf search domain(s) verbatim. 169.254.169.253 (the VPC's own Amazon-provided DNS Resolver) is a safe default for a standard VPC. Each node_pools entry has its own dns_servers field for the same reason on workers — not auto-wired from this one, since a pool could reasonably live in a different VPC."
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

variable "cni" {
  description = "CNI to install: 'default' or 'cilium'. Null (default) resolves to 'cilium' regardless of topology — Canal/flannel's iptables/ipset dataplane ('default') is broken on AlmaLinux 10, this project's only supported OS (its kernel dropped modules flannel and Felix require). 'default' remains an escape hatch for a consumer-supplied playbook targeting a different OS."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["default", "cilium"], var.cni)
    error_message = "cni must be null, 'default', or 'cilium'."
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
  description = "Candidate subnets by Name tag, in order of preference. A new cluster is placed in the first with a free address for the control plane and every static node without its own subnet_id; the whole cluster then stays in that subnet for good, even as it fills. Candidates may be in different availability zones. List form of subnet_name; see the aws-control-plane module."
  type        = list(string)
  default     = null
}

variable "subnet_name" {
  description = "Name tag of the subnet to launch the control-plane node into (control_plane_count = 1 only). Alternative to subnet_id."
  type        = string
  default     = null
}

variable "cluster_dns_name" {
  description = "Name to use in DNS in place of cluster_name, so that the FQDN is <cluster_dns_name>.<cluster_domain>. Null (the default) uses cluster_name. Set this where cluster_name carries something the domain already says: with cluster_name = \"app-red\" and cluster_domain = \"red.example.internal\", cluster_dns_name = \"app\" keeps the name app.red.example.internal while tags, resource names and the agent token parameter stay unique to that cluster."
  type        = string
  default     = null
  validation {
    condition     = var.cluster_dns_name == null || can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_dns_name))
    error_message = "cluster_dns_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "cluster_domain" {
  description = "Optional DNS suffix for the cluster, e.g. 'example.internal'. When set, the FQDN is <cluster_name>.<cluster_domain> and the wildcard is *.<cluster_name>.<cluster_domain>, with cluster_dns_name in place of cluster_name where it is set. Null = node is reachable by IP only."
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
  description = "AMI ID for the control-plane node(s) — typically the output of kube-image's AWS Packer build. Tested with AlmaLinux 10 (RHEL-family — node-bootstrap uses dnf and update-ca-trust). Null = latest AlmaLinux 10 for the derived architecture via data lookup (a stock image with no RKE2 pre-baked — much slower first boot than a kube-image AMI, same tradeoff as Proxmox's proxmox_template_vm_id)."
  type        = string
  default     = null
}

variable "os_image_name" {
  description = "AMI name for the control-plane node(s), e.g. kube-image's self-descriptive build name. Alternative to os_image_ami_id — resolved to an ID via a data lookup scoped to this account and the derived architecture. Accepts EC2 Name-filter wildcards (*, ?): a pattern with the build date/suffix omitted resolves to the most recent matching build. Ignored when os_image_ami_id is set."
  type        = string
  default     = null
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
  description = <<-EOT
    Named worker node groups keyed by group name (e.g. "platform"), each created via
    aws-static-node with this cluster's identity, join address and security groups wired in
    automatically. For capacity the cluster must always have; elastic capacity belongs in
    autoscaled_nodes. Empty map (the default) creates none.

    subnet_id defaults to the control plane's own, keeping the cluster in one availability zone.
  EOT
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
  }))
  default = {}
}

variable "platform_node_group" {
  description = "static_nodes key of the group that runs the platform stack, ingress included. The platform Application pins its components to that group's node-group label, the group alone takes the ingress security group, the wildcard DNS record points at its nodes, and platform_node_iam_role_name resolves to its role. Null leaves all of that on the control plane."
  type        = string
  default     = null

  validation {
    condition     = var.platform_node_group == null ? true : contains(keys(var.static_nodes), var.platform_node_group)
    error_message = "platform_node_group must name a static_nodes group."
  }
}

variable "power_schedule" {
  description = <<-EOT
    When the cluster's nodes run. days names the days it runs, in EventBridge Scheduler's form
    (MON-FRI, MON,WED,FRI); on the other days it is off. Unset, every day.

    At stop_time on each of those days, stops the control plane and static nodes and scales every
    autoscaled group to zero. With start_time, starts the control plane and static nodes again: on
    the same day when start_time is earlier than stop_time, or on the evening before when it is
    later, for hours that cross midnight. Without start_time nothing starts the cluster; it stays
    stopped until started by hand. Times are HH:MM on a 24-hour clock, in timezone.

    Null leaves the cluster running.
  EOT
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
  description = <<-EOT
    Roles cluster-autoscaler adds nodes to, keyed by role name (e.g. "workers"). Each instance type
    of a role is an EC2 Auto Scaling group from zero, in the control plane's subnet; for a pending
    pod the autoscaler picks the size that leaves the least capacity idle. Every node of a role
    carries kube-compute.io/node-group=<role>, its labels and its taints, whatever its size.

    max_cpu_cores and max_memory_gib cap what the role's nodes may add up to. cluster-autoscaler
    limits only cluster-wide totals, so with several roles it enforces the sum of their caps; each
    role's own groups are held to as many instances as fit its caps.

    The platform Application runs the autoscaler, and the platform node's IAM role gets its
    permissions. Every node of an autoscaled cluster registers its instance as its providerID, so
    adding the first role or removing the last replaces the control plane and static nodes.
  EOT
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
  description = <<-EOT
    Delete the cluster's dynamically provisioned EBS volumes when the cluster is destroyed.

    The CSI driver only releases a volume when its PVC is deleted through the API server, which
    a destroy never does -- the nodes go first and the volume is left detached and billed. This
    sweeps whatever still carries the cluster's ClusterName tag once the nodes are gone, so the
    platform chart must tag volumes with it (kube-platform's aws-ebs provisioner does).

    Turn it off where a volume is meant to outlive its cluster: a PersistentVolume kept with
    reclaimPolicy Retain is tagged the same as any other and would be swept.
  EOT
  type        = bool
  default     = true
}

variable "graceful_shutdown" {
  description = "How long kubelet holds up an OS shutdown to evict pods, so a node stopped by power_schedule -- or terminated by the autoscaler -- stops its workloads instead of having them killed with it. critical_seconds is the part of that reserved for critical pods, and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables the feature. Keep the total well under the two minutes a cloud gives an instance before it pulls the power."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}
}
