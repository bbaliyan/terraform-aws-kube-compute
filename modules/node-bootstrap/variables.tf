# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster name. Drives the kubeconfig server SAN."
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
  description = "Optional DNS suffix under which the platform's web-UI ingress hostnames are published (e.g. 'cluster-1.example.com' yields argocd.cluster-1.example.com). Distinct from cluster_fqdn, which is the API server name (api.<suffix>) — the ingress suffix must not carry the 'api.' prefix. Null/empty disables platform ingress."
  type        = string
  default     = null
}

variable "node_fqdn_label" {
  description = "Optional override for the fqdn's leftmost label (before cluster_fqdn_suffix), when it should differ from node_name. node_name is also this node's OS hostname and (on Proxmox) its VM/tag name in the provider UI, where a cluster-name prefix is useful for telling clusters apart at a glance; the fqdn already carries that identity in its suffix (cluster_fqdn_suffix embeds cluster_name), so repeating the prefix there is redundant. Null (the default) uses node_name for the label, preserving existing behavior."
  type        = string
  default     = null
}

variable "set_hostname" {
  description = "Whether this node's cloud-init sets an explicit hostname/fqdn. true (the default) writes hostname: <node_name> into cloud-config, required because RKE2/kubelet registers the node by OS hostname and every Terraform-provisioned node gets a distinct node_name. false omits hostname/fqdn entirely, relying on the VM platform's own per-instance metadata (e.g. a NoCloud datasource's local-hostname) to supply a unique hostname — needed when the SAME rendered cloud-init is shared across multiple VMs, e.g. CAPI MachineDeployment replicas (see proxmox-cluster's cluster_autoscaler_enabled, which sets this false — this module has no autoscaler-specific knowledge). Unverified for the false case: that the VM platform's metadata actually provides a usable per-VM hostname when cloud-config doesn't set one — real-hardware check required before trusting this in production."
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
  description = "Shared secret used to join a server to the cluster (rke2 config.yaml's token:). Required for node_role server-init and server-join alike — both receive the same freshly-generated cluster secret directly (no existing secret store to fetch a server token from). Sensitive: written into the cloud-init payload's 0600 /opt/kube-compute/secrets.env, sourced by the bootstrap script, never into config.yaml's world-readable siblings."
  type        = string
  default     = null
  sensitive   = true
}

variable "cluster_agent_token" {
  description = "Separate shared secret accepted only from agents (rke2 config.yaml's agent-token:) — a worker presenting this value can join as an agent but never as a server/etcd member. Only meaningful for node_role server-init (server-join callers omit it in every provider module checked). Sensitive: written into the cloud-init payload's 0600 /opt/kube-compute/secrets.env."
  type        = string
  default     = null
  sensitive   = true
}

variable "registration_address" {
  description = "IP or FQDN of the existing cluster's registration endpoint (a control plane's registration_address output). Used to build config.yaml's server: https://<address>:9345. Required for node_role server-join or worker; ignored for server-init."
  type        = string
  default     = null
}

variable "agent_token_fetch_command" {
  description = "Shell command that prints the rke2 agent join token to stdout when run on the node (e.g. a cloud provider's CLI call to fetch a secret from its parameter/secrets store). Required for node_role worker; ignored otherwise. Sensitive: some providers' fetch commands embed the raw token in the command string itself rather than fetching it out-of-band (e.g. Proxmox's node-pool module passes a literal `echo '<token>'`), so this is treated as sensitive uniformly and written into the cloud-init payload's 0600 /opt/kube-compute/secrets.env."
  type        = string
  default     = null
  sensitive   = true
}

variable "extra_tls_sans" {
  description = "Additional tls-san: entries for the rke2 server cert. Only meaningful for node_role = server-init or server-join."
  type        = list(string)
  default     = []
}

variable "cni" {
  description = "CNI to install: 'cilium' (the default — eBPF dataplane via kube-proxy replacement, no iptables/ipset/xtables dependency) or 'default' (whatever this distro's template installs out of the box — Canal/flannel+Calico). 'default' is not viable on AlmaLinux 10 (this project's only supported OS): its kernel dropped the legacy br_netfilter/xt_conntrack/xt_comment modules flannel and Felix's iptables dataplane both require. Kept as an escape hatch for a consumer-supplied image/template shipping a different CNI. Sets config.yaml's cni:/disable-kube-proxy: flags, and when 'cilium' on a genesis node, disables RKE2's own built-in HelmChart install of Cilium (disable: [rke2-cilium]) so bootstrap.sh's own apply of the kube-image-baked manifest never races it."
  type        = string
  default     = "cilium"
  validation {
    condition     = contains(["default", "cilium"], var.cni)
    error_message = "cni must be 'default' or 'cilium'."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) to add to the OS trust store via update-ca-trust, and to pin containerd's TLS verification of a registry_mirror_url host. Effect, not use case: a private or homelab CA, or null to skip. Sensitive: written directly into the cloud-init payload as the anchors file, base64-encoded."
  type        = string
  default     = null
  sensitive   = true
}

variable "trusted_ca_in_image" {
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. true keeps the PEM out of user data while still using its value for containerd's TLS pin and the platform Application's trustedCaPemB64 parameter. The bootstrap program fails the boot if the image does not carry the file."
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
  description = "Extra node-taint: entries applied at rke2 install time, each a full \"key=value:Effect\" string (e.g. [\"dedicated=true:NoSchedule\"]). Only meaningful for node_role = worker: the server roles fill the same single config.yaml key from control_plane_taint. A label and a nodeSelector make a node merely preferred; only a taint keeps other pods off it."
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
  description = "Argo CD platform Application source repo (kube-platform or a fork). Null/\"\" (the default) falls back to local.pinned_platform_repo_url — see that local for why the pin lives there rather than as this variable's default. Only takes effect when gitops_platform_enabled is true, and only meaningful for node_role = server-init."
  type        = string
  default     = null
}

variable "gitops_platform_revision" {
  description = "Branch/tag/SHA the platform Application tracks. Null/\"\" (the default) falls back to local.pinned_platform_revision — kube-platform's protected `main` branch, not a fixed commit — see that local for why. Override for a fork or to pin a specific revision instead."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, fully independent of the platform Application — no shared app-of-apps parent, no enforced ordering (Argo CD's own automated selfHeal/retry converges a workload that depends on something platform provides, once platform catches up). Null/empty (the default) = no workloads Application at all. Only meaningful for node_role = server-init."
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
  # genuinely different-shaped attributes (e.g. cluster-media's
  # gpuOperatorHelmValues vs. storageProvisionerHelmValues) -- "all map
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

variable "dns_self_register_zone" {
  description = "DNS zone (FQDN, trailing dot, e.g. 'lan.') the genesis node self-registers a single-target A record into via RFC2136/nsupdate, as soon as it knows its own IP. Null/empty (the default) disables self-registration entirely — every dns_self_register_*/dns_server_*/tsig_* variable is then ignored. Only meaningful for node_role = 'server-init'; ignored for server-join and worker."
  type        = string
  default     = null
}

variable "dns_self_register_record_name" {
  description = "Record name, relative to dns_self_register_zone (e.g. 'genesis.cluster-3' for zone 'lan.' registers 'genesis.cluster-3.lan.'). Required when dns_self_register_zone is set; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.dns_self_register_record_name != null
    error_message = "dns_self_register_record_name is required when dns_self_register_zone is set."
  }
}

variable "dns_self_register_ttl" {
  description = "TTL in seconds for the self-registered record. Only meaningful when dns_self_register_zone is set. Kept low by default: this record is republished on every apply via authoritative RFC2136 update, but a downstream caching resolver (e.g. a LAN router forwarding to the authoritative server) has no way to know that and keeps serving whatever it last cached for up to this TTL — on a reused cluster/record name that stale window directly delays every joining node."
  type        = number
  default     = 30
}

variable "dns_server_address" {
  description = "RFC2136 DNS server address the genesis node sends its nsupdate request to. Required when dns_self_register_zone is set; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.dns_server_address != null
    error_message = "dns_server_address is required when dns_self_register_zone is set."
  }
}

variable "dns_server_port" {
  description = "RFC2136 DNS server port. Only meaningful when dns_self_register_zone is set."
  type        = number
  default     = 53
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs (not this node's RFC2136 update target above — its ordinary pod/kubelet resolvers, e.g. the same list a caller already passes its own VM's network config). Null/empty (the default) skips writing a kubelet resolv-conf override, leaving kubelet's default ClusterFirst DNS policy in place: every pod inherits the node's own /etc/resolv.conf search domains. prefer_fqdn_over_hostname below already stops this node's own hostname from contributing a dangerous search entry, but the node can still pick up other search domains this module has no control over (e.g. a DHCP-provided domain) — if any of those turn out to be wildcarded, the same failure mode recurs: with the pod default ndots:5, a bare external hostname like \"github.com\" gets every search suffix tried before the bare name, so a wildcard match anywhere in that list silently resolves it to something inside that zone instead of the real host, breaking GitOps/external fetches from inside the cluster. Set this to give kubelet a resolv.conf with no search domain at all, closing that off regardless of where a dangerous search domain might come from."
  type        = list(string)
  default     = null
}

variable "dns_transport" {
  description = "Transport nsupdate uses to reach dns_server_address: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Only meaningful when dns_self_register_zone is set."
  type        = string
  default     = "udp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}

variable "tsig_key_name" {
  description = "TSIG key name authorizing the nsupdate request. Required when dns_self_register_zone is set; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.tsig_key_name != null
    error_message = "tsig_key_name is required when dns_self_register_zone is set."
  }
}

variable "tsig_key_algorithm" {
  description = "TSIG key algorithm (e.g. 'hmac-sha256'). Only meaningful when dns_self_register_zone is set."
  type        = string
  default     = "hmac-sha256"
}

variable "tsig_key_secret" {
  description = "Base64-encoded TSIG key secret. Required when dns_self_register_zone is set; ignored otherwise. Sensitive: written into the cloud-init payload's 0600 /opt/kube-compute/secrets.env, consumed by a 0600 keyfile the bootstrap script removes immediately after nsupdate."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.tsig_key_secret != null
    error_message = "tsig_key_secret is required when dns_self_register_zone is set."
  }
}

variable "genesis_apply_manifests" {
  description = "Ordered list of {path, content} manifests to write under /opt/kube-compute/manifests/ and apply via bootstrap.sh, each gated on its own readiness-wait if the caller's content needs one (this module does not interpret content — callers needing a wait embed it via a separate mechanism; see cluster_autoscaler_crd_wait_enabled below). Empty list (default) applies nothing beyond the existing platform/workloads Applications. Only meaningful for node_role = server-init — genesis-only, mirroring render_cilium/render_argocd."
  type = list(object({
    path    = string
    content = string
  }))
  default = []
}

variable "iscsi_initiator_enabled" {
  description = "Write a deterministic iSCSI InitiatorName (iqn.2026.lan.<cluster_name>:<node_fqdn_label, or node_name if unset>) to /etc/iscsi/initiatorname.iscsi and restart iscsid, replacing the OS-generated random one. Only meaningful where the image already has iscsi-initiator-utils baked in (kube-image's Proxmox template does; AWS uses EBS CSI and has no iSCSI initiator at all). Exists so an iSCSI target's initiator allow-list can be registered once, ahead of time, instead of re-discovered and re-registered by hand after every VM rebuild. False (the default) leaves the OS-generated random name untouched."
  type        = bool
  default     = false
}

variable "cluster_autoscaler_capi_install_baked" {
  description = "Whether the CAPI install manifest is baked onto the node image at /opt/kube-compute/manifests/capi-install.yaml and should be applied by bootstrap.sh. True suits the Proxmox template, which stages one; false suits AWS, whose image does not, and where Cluster API arrives as a platform Argo CD Application instead -- bootstrap.sh then only waits for the CRDs rather than installing them. Only meaningful when cluster_autoscaler_crd_wait_enabled is true."
  type        = bool
  default     = true
}

variable "cluster_autoscaler_crd_wait_enabled" {
  description = "Whether bootstrap.sh applies capi-install.yaml and waits for CAPI's core CRDs (machinedeployments.cluster.x-k8s.io) to be Established before applying genesis_apply_manifests entries. Only meaningful when genesis_apply_manifests is non-empty and contains CAPI-dependent content, and only takes effect for node_role = server-init."
  type        = bool
  default     = false
}

variable "aws_provider_id" {
  description = "Registers the node with providerID aws:///<zone>/<instance-id> and labels it node.kubernetes.io/instance-type, both read from EC2 instance metadata before RKE2 starts. cluster-autoscaler and the AWS cloud controller manager find a node's instance by the providerID. Any role takes the label, control plane included."
  type        = bool
  default     = false
}

variable "graceful_shutdown" {
  description = "How long kubelet holds up an OS shutdown to evict pods, so a node that is stopped on a schedule -- or terminated by an autoscaler -- stops its workloads instead of having them killed with it. critical_seconds is the part of that reserved for critical pods, and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables the feature, leaving pods to be killed when containerd goes down. Keep the total well under the two minutes a cloud gives an instance before it pulls the power."
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
