# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster name. It sets the clusterName Helm parameter, the iSCSI initiator name and CLUSTER_NAME in node.env."
  type        = string
}

variable "node_name" {
  description = "Unique per-node name, set as this node's cloud-init hostname (and fqdn, when cluster_fqdn_suffix is set). RKE2/kubelet defaults the registered Kubernetes node name to the OS hostname, so every node in a multi-node cluster MUST get a distinct value here."
  type        = string
}

variable "cluster_fqdn" {
  description = "Optional DNS name for the API/kubeconfig server and an extra TLS SAN. Null = use the node IP only."
  type        = string
  default     = null
}

variable "cluster_fqdn_suffix" {
  description = "Optional DNS suffix for the platform web UI hostnames (e.g. 'my-cluster.example.com' gives argocd.my-cluster.example.com). It differs from cluster_fqdn and must not start with 'api.'. Null or empty disables platform ingress."
  type        = string
  default     = null
}

variable "node_fqdn_label" {
  description = "Optional override for the leftmost fqdn label (before cluster_fqdn_suffix). Null (the default) uses node_name. The fqdn suffix already carries the cluster name, so a cluster-name prefix here is redundant."
  type        = string
  default     = null
}

variable "set_hostname" {
  description = "Whether cloud-init sets hostname and fqdn from node_name. true (the default) is required for a node with its own render, because RKE2 registers by OS hostname. false omits both keys, for a render shared by several VMs such as an Auto Scaling group."
  type        = bool
  default     = true
}

variable "node_role" {
  description = "Bootstrap role this node is being installed for: 'server-init' (first control-plane node — forms the etcd cluster), 'server-join' (an additional control-plane node), or 'worker' (joins as an agent only, no control plane)."
  type        = string
  validation {
    condition     = contains(["server-init", "server-join", "worker"], var.node_role)
    error_message = "node_role must be one of: server-init, server-join, worker."
  }
}

variable "control_plane_taint" {
  description = "When true, the rke2 server install adds a node-taint: CriticalAddonsOnly=true:NoExecute so user workloads are excluded from this control-plane node. Only meaningful for node_role = server-init or server-join."
  type        = bool
  default     = false
}

variable "cluster_token" {
  description = "Shared secret that joins a server to the cluster (config.yaml token). Required for server-init and server-join. Sensitive: written to the 0600 /etc/rancher/rke2/config.yaml."
  type        = string
  default     = null
  sensitive   = true
}

variable "cluster_agent_token" {
  description = "Separate secret accepted only from agents (config.yaml agent-token), so a worker can join as an agent but never as a server. Used only for server-init. Sensitive: written to the 0600 /etc/rancher/rke2/config.yaml."
  type        = string
  default     = null
  sensitive   = true
}

variable "registration_address" {
  description = "IP or FQDN of the existing cluster's registration endpoint (a control plane's registration_address output). Required for server-join and worker. Optional for server-init: if set, the node probes it at boot and joins the cluster that answers (rejoin probe)."
  type        = string
  default     = null
}

variable "rejoin_probe_addresses" {
  description = "IPs or FQDNs a server-init node probes in order before it starts etcd. It joins the first cluster that answers and initializes a new one only if none does. Use it when registration_address points at the node itself. Empty (the default) probes registration_address."
  type        = list(string)
  default     = []
}

variable "agent_token_fetch_command" {
  description = "Shell command that prints the rke2 agent join token to stdout on the node, for example a cloud CLI call that reads a secrets store. Required for node_role worker; ignored otherwise. Sensitive: it is written to the 0600 /opt/kube-compute/secrets.env."
  type        = string
  default     = null
  sensitive   = true
}

variable "extra_tls_sans" {
  description = "Additional tls-san: entries for the rke2 server cert. Only meaningful for node_role = server-init or server-join."
  type        = list(string)
  default     = []
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) to add to the OS trust store via update-ca-trust, and to pin containerd's TLS verification of a registry_mirror_url host. Effect, not use case: a private CA, or null to skip. Sensitive: written directly into the cloud-init payload as the anchors file, base64-encoded."
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
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream registries directly."
  type        = string
  default     = null
}

variable "node_labels" {
  description = "Extra node-label: entries applied at rke2 install time, e.g. { \"topology.kubernetes.io/zone\" = \"eu-west-1a\" }. Only meaningful for node_role = worker."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Extra node-taint entries applied at RKE2 install time, each a full 'key=value:Effect' string (e.g. ['dedicated=true:NoSchedule']). Only for node_role = worker; server roles use control_plane_taint. Only a taint keeps other pods off a node."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.node_taints : can(regex("^[^=:]+=[^=:]*:(NoSchedule|PreferNoSchedule|NoExecute)$", t))])
    error_message = "each node_taints entry must be key=value:Effect, where Effect is NoSchedule, PreferNoSchedule, or NoExecute."
  }
}

variable "extra_server_manifests" {
  description = "Arbitrary RKE2 auto-deploy manifest files (filename => full YAML content) written to /var/lib/rancher/rke2/server/manifests/ on server-init/server-join nodes only. This module does not interpret the content."
  type        = map(string)
  default     = {}
}

variable "gitops_platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = skip Argo CD and the platform Application entirely (a bare RKE2+Cilium cluster) regardless of gitops_platform_repo_url/_revision. Only meaningful for node_role = server-init."
  type        = bool
  default     = true
}

variable "gitops_platform_repo_url" {
  description = "Source repo of the Argo CD platform Application (kube-platform or a fork). Null or empty (the default) uses local.pinned_platform_repo_url. The genesis node also clones it for its Cilium and Argo CD manifests. Only for server-init."
  type        = string
  default     = null
}

variable "gitops_platform_revision" {
  description = "Branch, tag or SHA the platform Application tracks. The genesis node clones the same ref for its boot manifests (40 hex digits means a commit). Null or empty (the default) uses local.pinned_platform_revision, the protected main branch of kube-platform."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional source repo of a workloads Application, independent of the platform Application and with no ordering between them. Null or empty (the default) creates none. Only for node_role = server-init."
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

variable "workloads_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the workloads Application. Only meaningful when gitops_workloads_repo_url is set."
  type        = map(string)
  default     = {}
}

variable "workloads_helm_values_object" {
  # any and the try() fallback in locals, for the same reasons as
  # platform_helm_values_object below.
  description = "Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations."
  type        = any
  default     = null
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. 'selfsigned' needs no dependencies. 'byo' expects a Secret named byo-ca-tls in the cert-manager namespace. 'acme' requires DNS-01 config (separate setup)."
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

variable "platform_helm_values_object" {
  # any, not map(any): map(any) forces every top-level value to unify to one
  # common type, which breaks the moment two callers' objects have
  # genuinely different-shaped attributes (e.g. a list value next to
  # a nested object) -- "all map
  # elements must have the same type". Stays `any`; the null-fallback in
  # locals.platform_values_object uses try(), not a `? :` ternary or
  # coalesce(), specifically because try() is the one HCL construct whose
  # own arguments are exempt from static type-consistency checking.
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags forwarded to the platform bootstrap Application (as part of helm.valuesObject.extraTags) so Kubernetes-managed resources can tag themselves consistently with the node's own tags."
  type        = map(string)
  default     = {}
}

variable "dns_servers" {
  description = "Resolver IPs for kubelet and pods, for example the list your VM network config uses. Null or empty (the default) leaves kubelet on the node's own /etc/resolv.conf. A list writes a kubelet resolv.conf with no search domain. See the README, section \"DNS search domains\"."
  type        = list(string)
  default     = null
}

variable "graceful_shutdown" {
  description = "How long kubelet delays an OS shutdown to evict pods. critical_seconds is the part reserved for critical pods and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables it. Keep the total well under 2 minutes."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}

  validation {
    condition     = var.graceful_shutdown == null ? true : var.graceful_shutdown.seconds > var.graceful_shutdown.critical_seconds
    error_message = "graceful_shutdown.seconds must exceed critical_seconds: critical pods are evicted inside the same window, not after it."
  }

  validation {
    condition     = var.graceful_shutdown == null ? true : var.graceful_shutdown.critical_seconds > 0
    error_message = "graceful_shutdown.critical_seconds must be greater than zero."
  }
}

variable "os_auto_updates" {
  description = "Install OS updates daily with dnf-automatic, without rebooting, once the node has joined. RKE2 packages are excluded, because system-upgrade-controller upgrades them. Also installs yum-utils, whose needs-restarting reports a due reboot. False leaves packages as baked."
  type        = bool
  default     = true
}

variable "provider_steps" {
  description = "Boot steps owned by one provider. The provider module builds them, so this module holds no provider logic. Each has a name and cloud-init runcmd commands (a command is a list of strings). They run in order before the module's own commands."
  type = list(object({
    name     = string
    commands = list(list(string))
  }))
  default = []

  validation {
    condition     = length(distinct([for step in var.provider_steps : step.name])) == length(var.provider_steps)
    error_message = "provider_steps: every step name must be unique."
  }
}

variable "provider_files" {
  description = "Files that the provider steps need, written by cloud-init before any command runs. Sensitive content is allowed."
  type = list(object({
    path        = string
    content     = string
    permissions = optional(string, "0644")
  }))
  default = []
}
