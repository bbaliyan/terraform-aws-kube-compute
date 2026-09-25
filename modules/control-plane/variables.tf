# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
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
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. Passed through to node-bootstrap, which then keeps the PEM out of user data."
  type        = bool
  default     = false
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs, passed through to node-bootstrap to give kubelet a search-domain-free resolv-conf — defense in depth against any node-inherited DNS search domain colliding with a wildcard cluster DNS record (*.<cluster>.<domain>, see cluster_domain), on top of node-bootstrap's own prefer_fqdn_over_hostname fix for the specific hostname-derived case (e.g. a VPC DHCP-provided domain this module has no control over, if that ever turns out to be wildcarded too). Null/empty (the default) leaves kubelet's default ClusterFirst DNS policy in place: every pod inherits this node's own /etc/resolv.conf search domain(s) verbatim. 169.254.169.253 (the VPC's own Amazon-provided DNS Resolver, reachable from any subnet regardless of the VPC's DHCP option set) is a safe default for a standard VPC; use the account's actual resolver(s) if the VPC's DHCP options point elsewhere."
  type        = list(string)
  default     = null
}

variable "gitops_platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application. Sourced from this cluster's cluster-facts unit."
  type        = bool
  default     = true
}

variable "gitops_platform_repo_url_override" {
  description = "Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin. Sourced from this cluster's cluster-facts unit."
  type        = string
  default     = null
}

variable "gitops_platform_revision_override" {
  description = "Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default. Sourced from this cluster's cluster-facts unit."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application. Sourced from this cluster's cluster-facts unit."
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

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region the node runs in. Exposed as an output so the SSM control-plane scripts know which region to target. Does NOT configure the provider — the caller sets the provider region; pass the same value here."
  type        = string
}

variable "cluster_type" {
  description = "Cluster topology intent: 'all_in_one' (control-plane nodes stay schedulable — every single-node cluster, and a small HA cluster doing double duty) or 'dedicated_control_plane' (control-plane nodes are tainted so user workloads run only on separate node pools). Taint cannot be derived from worker count because node pools are separate state this module cannot see."
  type        = string
  default     = "all_in_one"
  validation {
    condition     = contains(["all_in_one", "dedicated_control_plane"], var.cluster_type)
    error_message = "cluster_type must be 'all_in_one' or 'dedicated_control_plane'."
  }
}

variable "cni" {
  description = "CNI to install: 'default' or 'cilium'. Null (default) resolves to 'cilium' regardless of topology — Canal/flannel's iptables/ipset dataplane ('default') is broken on AlmaLinux 10, this project's only supported OS (its kernel dropped modules flannel and Felix require). 'default' remains selectable as an escape hatch for a consumer-supplied playbook targeting a different OS. Set explicitly to override."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["default", "cilium"], var.cni)
    error_message = "cni must be null, 'default', or 'cilium'."
  }
}

variable "control_plane_count" {
  description = "Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain. 3 or 5 places one control-plane node per availability zone behind an internal NLB (see control_plane_subnets)."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3, or 5."
  }
}

variable "control_plane_subnets" {
  description = "Map of availability zone -> subnet id for control-plane placement, required when control_plane_count > 1 (one control-plane node per AZ, across at least 3 distinct AZs — the map's keys ARE those AZs, so the module needs no lookup to discover them). Ignored when control_plane_count = 1 — use subnet_id/subnet_name instead. The module never creates fabric; every value must be an existing subnet's id, already located in the AZ given by its key."
  type        = map(string)
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || var.control_plane_subnets != null
    error_message = "control_plane_subnets is required when control_plane_count > 1 (the module does not auto-discover multi-AZ subnets for the HA control plane)."
  }
}

variable "endpoint_mode" {
  description = "How joining nodes reach the registration endpoint once control_plane_count > 1 (ignored for control_plane_count = 1, which has no endpoint at all): \"loadbalancer\" (default) creates an internal NLB; \"dns\" creates Route53 multivalue-answer A records with CloudWatch-alarm-backed health checks (cheaper, TTL-bound failover; requires cluster_domain plus a resolvable hosted zone); \"static\" creates neither and uses static_registration_address verbatim (bring your own load balancer/address)."
  type        = string
  default     = "loadbalancer"
  validation {
    condition     = contains(["loadbalancer", "dns", "static"], var.endpoint_mode)
    error_message = "endpoint_mode must be one of: loadbalancer, dns, static."
  }
}

variable "static_registration_address" {
  description = "Consumer-supplied registration endpoint address (e.g. your own load balancer's DNS name), used verbatim as registration_address when endpoint_mode = \"static\". Ignored otherwise. The module creates no load balancer or DNS record for this mode — you own that infrastructure."
  type        = string
  default     = null

  validation {
    condition     = var.endpoint_mode != "static" || var.static_registration_address != null
    error_message = "static_registration_address is required when endpoint_mode = \"static\"."
  }
}

# Networking: the module takes a network HANDLE and never creates fabric (VPC/subnet/IGW/NAT).
variable "subnet_id" {
  description = <<-EOT
    Subnet to launch the node into. Pass it to plug in your own networking. Null = the module
    falls back to a subnet in the account's DEFAULT VPC (a data lookup; the module never CREATES a
    VPC/subnet). Accounts whose default VPC was deleted must pass a subnet_id or subnet_name.
  EOT
  type        = string
  default     = null
}

variable "vpc_name" {
  description = "Name tag of the VPC. Pair with subnet_name to scope the subnet lookup to a specific VPC. Ignored when subnet_id is used."
  type        = string
  default     = null
}

variable "subnet_name" {
  description = "Name tag of the subnet to launch the node into. Alternative to subnet_id — the module resolves the ID via a data lookup. Pair with vpc_name when the name tag is not globally unique."
  type        = string
  default     = null
}

variable "subnet_names" {
  description = <<-EOT
    Candidate subnets by Name tag, in order of preference. A new cluster is placed in the first one
    with subnet_min_free_ips free addresses, so a full subnet, or one too nearly full to take the
    cluster, falls through to the next. The list form of subnet_name.

    The choice is made once. A cluster whose control plane already exists, running or stopped,
    stays in that control plane's subnet whatever this list says or however full that subnet
    becomes: it is never moved by an apply. The candidates may be in different availability zones,
    since a cluster only ever occupies the one it was placed in. To move a cluster, destroy it and
    apply again.
  EOT
  type        = list(string)
  default     = null

  validation {
    condition     = var.subnet_names == null || length(var.subnet_names) > 0
    error_message = "subnet_names must be null or a non-empty list; an empty list selects nothing."
  }

  validation {
    condition     = var.subnet_names == null || var.subnet_name == null
    error_message = "Set subnet_name or subnet_names, not both."
  }
}

variable "subnet_min_free_ips" {
  description = "Free IP addresses a subnet_names candidate needs before a new cluster is placed in it: one for each node launched with the cluster, not only the control plane. aws-cluster passes the control plane plus its static nodes. Nodes added later, by the autoscaler, are not counted."
  type        = number
  default     = 1

  validation {
    condition     = var.subnet_min_free_ips >= 1
    error_message = "subnet_min_free_ips must be at least 1."
  }
}

# DNS: optional convenience. The module never owns DNS as a hard dependency — if you don't pass a
# zone, it creates no record and you register the wildcard (see the wildcard_dns_name output) in
# whatever DNS you run (Route53, a local resolver, RFC2136, external-dns, sslip.io fallback...).
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
  description = "Name of the Route53 private hosted zone (e.g. \"example.internal\"). Alternative to hosted_zone_id — the module resolves the ID via a data lookup. Requires cluster_domain to be set."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID. Alternative to hosted_zone_name — pass the literal ID. Requires cluster_domain to be set. Null = create no record; register DNS yourself using the wildcard_dns_name output."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type (bundles vCPU + memory). CPU arch (arm64/x86_64) is derived from the family prefix for AMI selection."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = <<-EOT
    AMI ID for the node. Tested with AlmaLinux 10 (RHEL-family — node-bootstrap uses dnf and
    update-ca-trust). Other RHEL-family images (Rocky, AL2023) may work but are untested —
    no compatibility guarantee. Null = latest AlmaLinux 10 for the derived architecture via
    data lookup.
  EOT
  type        = string
  default     = null
}

variable "os_image_name" {
  description = <<-EOT
    AMI name for the node, e.g. kube-image's self-descriptive build name. Alternative to
    os_image_ami_id — the module resolves the ID via a data lookup scoped to this account's
    own AMIs and the derived architecture. Accepts EC2 Name-filter wildcards (*, ?): a
    pattern with the build date/suffix omitted resolves to the most recent matching build.
    Ignored when os_image_ami_id is set.
  EOT
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
}

variable "ingress_ports" {
  description = "TCP ports opened on the module SG: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH)."
  type        = list(number)
  default     = [80, 443, 6443]
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB). Covers OS + container image cache."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...)."
  type        = string
  default     = "gp3"
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. Passed through to the node-bootstrap platform Application parameters. 'selfsigned' (default), 'byo' (consumer provides byo-ca-tls Secret), 'acme' (ACME DNS-01)."
  type        = string
  default     = "selfsigned"
  validation {
    condition     = contains(["selfsigned", "byo", "acme"], var.cert_mode)
    error_message = "cert_mode must be 'selfsigned', 'byo', or 'acme'."
  }
}

variable "platform_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. See node-bootstrap for full description."
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
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags applied to every AWS resource this module creates (EC2 instance, root EBS volume, security group, IAM role), and forwarded to node-bootstrap so platform-managed resources (e.g. CSI-provisioned storage) can tag themselves consistently."
  type        = map(string)
  default     = {}
}

variable "aws_provider_id" {
  description = "Registers every control-plane node with providerID aws:///<zone>/<instance-id>. Needed on every node of a cluster whose nodes cluster-autoscaler and the AWS cloud controller manager look up by instance. Changing it replaces the nodes."
  type        = bool
  default     = false
}

variable "manage_wildcard_dns_record" {
  description = "Whether this module owns the *.<cluster>.<domain> A record. aws-cluster sets it false when ingress runs on a platform node group and points the record there itself. The explicit api.<cluster>.<domain> record is created either way, and a specific name beats a wildcard, so the join address keeps resolving to the control plane."
  type        = bool
  default     = true
}

variable "graceful_shutdown" {
  description = "How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}
}

variable "destroy_after" {
  description = "Something that must outlive this module's nodes at destroy. It orders their destruction and nothing else, so it is never read as a value."
  type        = string
  default     = null
}
