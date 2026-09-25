# SPDX-License-Identifier: Apache-2.0
# node-bootstrap renders a lean cloud-init payload. It executes NOTHING: no
# null_resource, no local-exec, no Ansible, no connection to the node. The
# heavy half of RKE2 bootstrap (OS prep, RKE2 binaries, SELinux policy, kernel
# modules, guest agent) is baked into a kube-image template; what's left here
# is per-cluster identity, secrets, and join logic — what can't be baked into
# a shared image.
locals {
  # Single source of truth for the kube-platform pin, held directly here — this
  # is node-bootstrap's only remaining consumer, so a separate component-versions
  # module was pure indirection. NOT the gitops_platform_repo_url/_revision
  # variables' own defaults: an explicit null/"" passed through a module call
  # does NOT fall through to the callee's variable default the way an omitted
  # argument would (that convenience is specific to optional() object-type
  # attributes) — verified the hard way on a real apply; the regression test
  # in tests/platform_pin.tftest.hcl locks it in. coalesce() is the fix, since
  # it treats null and "" identically. Tracks kube-platform's protected `main`
  # branch, not a pinned SHA — branch protection is the safeguard replacing
  # the reproducibility a SHA pin would give.
  pinned_platform_repo_url = "https://github.com/bbaliyan/kube-platform.git"
  pinned_platform_revision = "main"

  # gitops_platform_enabled = false clears the repo URL to "" regardless of the
  # pin, so every gate downstream can keep testing "repo_url non-empty" as the
  # single signal, matching gitops_workloads_repo_url's null-means-skip shape.
  effective_gitops_platform_repo_url = var.gitops_platform_enabled ? coalesce(var.gitops_platform_repo_url, local.pinned_platform_repo_url) : ""
  effective_gitops_platform_revision = coalesce(var.gitops_platform_revision, local.pinned_platform_revision)

  effective_gitops_workloads_repo_url = var.gitops_workloads_repo_url != null ? var.gitops_workloads_repo_url : ""

  platform_app_enabled  = local.effective_gitops_platform_repo_url != ""
  workloads_app_enabled = local.effective_gitops_workloads_repo_url != ""
  # Argo CD itself is only needed when at least one of the two Applications is
  # going to be applied — a non-empty sentinel covers both.
  argocd_needed = local.platform_app_enabled || local.workloads_app_enabled

  # nsupdate's `zone` directive requires a fully-qualified (trailing-dot) name,
  # but callers commonly pass a bare zone (e.g. "lan"). Normalize here so
  # either form works identically, mirroring proxmox-control-plane's own
  # local.dns_zone. Idempotent; both null and "" stay "" so the
  # no-self-registration path is unaffected.
  dns_self_register_zone = var.dns_self_register_zone != null && var.dns_self_register_zone != "" ? "${trimsuffix(var.dns_self_register_zone, ".")}." : ""

  # nsupdate transport flags, derived exactly as the Ansible role derived them:
  # -v forces TCP, -4/-6 pin the address family.
  nsupdate_flags = trimspace(join(" ", compact([
    startswith(var.dns_transport, "tcp") ? "-v" : "",
    endswith(var.dns_transport, "4") ? "-4" : "",
    endswith(var.dns_transport, "6") ? "-6" : "",
  ])))

  is_server = contains(["server-init", "server-join"], var.node_role)

  # Whether bootstrap.sh should apply the Cilium/Argo CD manifests kube-image
  # already baked onto every template at /opt/kube-compute/manifests/ — a
  # per-cluster runtime decision (CNI choice, GitOps enablement), independent
  # of whether the files exist on disk (they always do). This module renders
  # neither: the live `helm template` render that used to happen here exceeded
  # Proxmox's 1 MiB cicustom snippet cap on a real apply — see kube-image's
  # packer/proxmox/build.sh and helm-values/ for where the render moved.
  render_cilium = var.cni == "cilium" && var.node_role == "server-init"
  render_argocd = local.argocd_needed && var.node_role == "server-init"

  # Genesis-only, same as render_cilium/render_argocd — but deliberately NOT
  # gated on argocd_needed/render_argocd: an arbitrary genesis-apply manifest
  # (e.g. proxmox-cluster's CAPI/CAPMOX cluster-autoscaler bundle) is applied
  # by bootstrap.sh as a one-time genesis step, independent of whether this
  # cluster also runs a platform or workloads Argo CD Application. Tying it to
  # render_argocd would mean gitops_platform_enabled = false callers never get
  # the write_files entries bootstrap.sh's apply step expects. This module
  # does not render or interpret genesis_apply_manifests' content — that
  # happens in the composing module (e.g. proxmox-cluster), which has access
  # to inputs (like module.control_plane's outputs) this leaf module does not.
  effective_genesis_apply_manifests = var.node_role == "server-init" ? var.genesis_apply_manifests : []
  effective_crd_wait_enabled        = var.node_role == "server-init" && var.cluster_autoscaler_crd_wait_enabled
  genesis_apply_manifest_paths      = [for m in local.effective_genesis_apply_manifests : m.path]

  # Rendered by templatefile()/yamlencode() here, not on the node — keeps the
  # node free of any templating engine.
  #
  # try(), not a `? :` ternary or coalesce() -- see the note on the
  # platform_helm_values_object variable declaration. try()'s own arguments
  # are exempt from OpenTofu's static "Inconsistent conditional result
  # types" check, so this falls back to {} on null without needing var.x's
  # object type to unify with {}'s, regardless of which attributes the
  # caller's object carries. Verified in isolation (both the null case and
  # a concrete multi-attribute object case plan cleanly) before relying on
  # it here.
  platform_values_object = merge(
    try(var.platform_helm_values_object, {}),
    { extraTags = var.extra_tags },
  )

  workloads_values_object = try(var.workloads_helm_values_object, {})

  workloads_helm_configured = (
    length(var.workloads_extra_helm_parameters) > 0 ||
    var.workloads_helm_values_object != null
  )

  # kube-platform's bootstrap chart reads a clusterAutoscalerEnabled Helm
  # value to decide whether to deploy the cluster-autoscaler Argo CD
  # Application (bootstrap/templates/cluster-autoscaler-app.yaml). This
  # module doesn't own that decision (proxmox-cluster does), so it's not a
  # hardcoded parameter here — the composing module passes it through the
  # generic platform_extra_helm_parameters map instead. Omitting it falls
  # back to kube-platform's own chart default (false).
  #
  # Multi-source Application: the second source (ref: values, no chart)
  # makes platform-versions/values.yaml available to the first source's
  # `helm.valueFiles`, so bootstrap's chart templates (cilium-app.yaml,
  # argocd-app.yaml) can read .Values.ciliumVersion/.Values.argocdVersion at
  # every sync — same mechanism system-upgrade-plans-app.yaml uses for
  # .Values.k8sVersion. This is what makes bumping platform-versions/values.yaml
  # alone enough to roll Cilium/Argo CD forward kube-platform-wide, with no
  # per-cluster apply and no editing the Application templates themselves.
  platform_app_yaml = <<-EOT
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: platform
      namespace: argocd
    spec:
      project: default
      sources:
        - repoURL: ${local.effective_gitops_platform_repo_url}
          targetRevision: ${local.effective_gitops_platform_revision}
          path: bootstrap
          helm:
            valueFiles:
              - $values/platform/platform-versions/values.yaml
            parameters:
              - name: platformRepoURL
                value: "${local.effective_gitops_platform_repo_url}"
              - name: platformRevision
                value: "${local.effective_gitops_platform_revision}"
              - name: certMode
                value: "${var.cert_mode}"
              - name: clusterName
                value: "${var.cluster_name}"
              - name: clusterFqdnSuffix
                value: "${var.cluster_fqdn_suffix != null ? var.cluster_fqdn_suffix : ""}"
              - name: trustedCaPemB64
                value: "${base64encode(var.trusted_ca_pem != null ? var.trusted_ca_pem : "")}"
    %{~for name, val in var.platform_extra_helm_parameters~}
              - name: ${name}
                value: "${val}"
    %{~endfor~}
            valuesObject:
              ${indent(14, yamlencode(local.platform_values_object))}
        - repoURL: ${local.effective_gitops_platform_repo_url}
          targetRevision: ${local.effective_gitops_platform_revision}
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
  EOT

  # Deliberately independent of the platform Application: no shared app-of-apps
  # parent, no sync-wave ordering against it. Eventual consistency — if a
  # workload needs something platform provides, Argo CD's own automated
  # selfHeal/retry converges it once platform catches up.
  workloads_app_yaml = <<-EOT
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: workloads
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: ${local.effective_gitops_workloads_repo_url}
        targetRevision: ${var.gitops_workloads_revision}
        path: ${var.gitops_workloads_path}
    %{~if local.workloads_helm_configured~}
        helm:
    %{~if length(var.workloads_extra_helm_parameters) > 0~}
          parameters:
    %{~for name, val in var.workloads_extra_helm_parameters~}
            - name: ${name}
              value: "${val}"
    %{~endfor~}
    %{~endif~}
    %{~if var.workloads_helm_values_object != null~}
          valuesObject:
            ${indent(12, yamlencode(local.workloads_values_object))}
    %{~endif~}
    %{~else~}
        directory:
          recurse: true
    %{~endif~}
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
  EOT

  # Ported from registries.yaml.j2, including the containerd TLS pin to the
  # same anchors path the trusted CA is written to.
  registry_mirror_host = var.registry_mirror_url != null ? replace(var.registry_mirror_url, "/^https?:\\/\\//", "") : ""

  registries_yaml = var.registry_mirror_url == null ? "" : join("\n", concat([
    "mirrors:",
    "  docker.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    "  ghcr.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    "  quay.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    "  registry.k8s.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    ], var.trusted_ca_pem == null ? [] : [
    "configs:",
    "  \"${local.registry_mirror_host}\":",
    "    tls:",
    "      ca_file: /etc/pki/ca-trust/source/anchors/trusted-ca.crt",
  ], [""]))

  # Everything in config.yaml known at plan time. Node-discovered parts
  # (node-ip, its own IP as the first tls-san, the fetched agent token, the
  # rejoin-probe result) are appended by bootstrap.sh on the node itself.
  # Every SAN is quoted: a wildcard entry starts with '*', YAML's alias
  # indicator, so an unquoted "- *.foo" is invalid YAML and RKE2 refuses to
  # start. Quoting is inert for plain IPs/hostnames.
  static_tls_san_block = join("\n", [
    for san in compact(concat([var.cluster_fqdn != null ? var.cluster_fqdn : ""], var.extra_tls_sans)) :
    "  - \"${san}\""
  ])

  server_static_block = join("\n", concat([
    "write-kubeconfig-mode: \"0644\"",
    "secrets-encryption: true",
    "disable-cloud-controller: true",
    # Disables whatever RKE2's default ingress controller is for the installed
    # version (ingress-nginx or Traefik) — this project doesn't bundle one at
    # bootstrap.
    "ingress-controller: none",
    # RKE2 does not expose etcd's Prometheus metrics endpoint (a separate port,
    # 2381, distinct from etcd's client port 2379) unless explicitly told to.
    # Without this, kube-platform's kube-prometheus-stack has nothing to scrape
    # on 2381 regardless of its own ServiceMonitor config. Safe unconditionally:
    # it only exposes a metrics endpoint, it doesn't change etcd's behavior, and
    # etcd only runs on server nodes anyway.
    "etcd-expose-metrics: true",
    # The control plane runs as static pods on the node. With requests the scheduler
    # counts its memory; the node reservation below covers only what runs outside pods.
    "control-plane-resource-requests: \"kube-apiserver-cpu=250m,kube-apiserver-memory=1024Mi,etcd-cpu=200m,etcd-memory=512Mi,kube-controller-manager-cpu=200m,kube-controller-manager-memory=256Mi,kube-scheduler-cpu=100m,kube-scheduler-memory=128Mi\"",
    ], var.control_plane_taint ? [
    "node-taint:",
    "  - \"CriticalAddonsOnly=true:NoExecute\"",
    ] : [], var.cni == "cilium" ? [
    "cni: cilium",
    "disable-kube-proxy: true",
    # Without this, RKE2 installs its own bundled rke2-cilium addon (a separate
    # HelmChart CR) alongside the genesis-rendered Cilium manifest — both
    # fighting over the same cilium-operator/cilium objects in kube-system.
    "disable:",
    "  - rke2-cilium",
  ] : []))

  node_label_block = length(var.node_labels) == 0 ? "" : join("\n", concat(
    ["node-label:"],
    [for k, v in var.node_labels : "  - \"${k}=${v}\""],
  ))

  # Worker-only: the server roles fill config.yaml's single node-taint: key from
  # control_plane_taint, and a second block would be a duplicate key RKE2
  # refuses to start on. Quoted for the same reason every tls-san entry is.
  node_taint_block = length(var.node_taints) == 0 ? "" : join("\n", concat(
    ["node-taint:"],
    [for t in var.node_taints : "  - \"${t}\""],
  ))

  # kubelet's default ClusterFirst DNS policy copies the NODE's own
  # /etc/resolv.conf search domains into every pod. NetworkManager derives a
  # search domain from this node's FQDN hostname (cluster_fqdn_suffix) — the
  # same zone a wildcard cluster DNS record (*.<cluster>.<domain>) answers
  # for. With the pod's default ndots:5, a bare external hostname like
  # "github.com" gets that search suffix tried FIRST, silently resolving to
  # the cluster's own wildcard IP instead of the real host — confirmed on a
  # real cluster-1 apply: Argo CD's repo-server tried to git-clone github.com
  # against the node's own IP over HTTPS and got connection refused. Pointing
  # kubelet at a search-domain-free resolv.conf (var.dns_servers only, no
  # `search` line) fixes every pod on the node, without touching the node's
  # own OS resolv.conf (kept search-enabled for host-level convenience).
  # Opt-in via var.dns_servers so a caller that doesn't pass it keeps the old
  # behavior rather than erroring.
  kubelet_resolv_conf_enabled = var.dns_servers != null && length(var.dns_servers) > 0
  kubelet_resolv_conf_path    = "/etc/rancher/rke2/resolv-conf-no-search.conf"
  kubelet_resolv_conf_content = join("\n", concat(
    [for ip in coalesce(var.dns_servers, []) : "nameserver ${ip}"],
    [""],
  ))
  # Applies to every role (server-init, server-join, worker) — kubelet runs
  # on all three and pollutes every pod scheduled to that node identically.
  kubelet_resolv_conf_block = !local.kubelet_resolv_conf_enabled ? "" : join("\n", [
    "kubelet-arg:",
    "  - \"resolv-conf=${local.kubelet_resolv_conf_path}\"",
  ])

  graceful_shutdown_enabled = var.graceful_shutdown != null

  # A kubelet drop-in, because shutdownGracePeriod has no command-line flag and so cannot go
  # through RKE2's kubelet-arg like the settings above. config-dir merges this over the config
  # RKE2 generates, which stays untouched.
  graceful_shutdown_config_dir = "/etc/rancher/rke2/kubelet.conf.d"

  graceful_shutdown_kubelet_config = !local.graceful_shutdown_enabled ? "" : join("\n", [
    "apiVersion: kubelet.config.k8s.io/v1beta1",
    "kind: KubeletConfiguration",
    "shutdownGracePeriod: ${var.graceful_shutdown.seconds}s",
    "shutdownGracePeriodCriticalPods: ${var.graceful_shutdown.critical_seconds}s",
    "",
  ])

  graceful_shutdown_arg_block = !local.graceful_shutdown_enabled ? "" : join("\n", [
    "kubelet-arg+:",
    "  - \"config-dir=${local.graceful_shutdown_config_dir}\"",
    "",
  ])

  # kubelet asks logind to delay the shutdown and gets no longer than InhibitDelayMaxSec, which
  # defaults to 5 seconds. Left alone it silently caps the grace period above to that.
  graceful_shutdown_logind_config = !local.graceful_shutdown_enabled ? "" : join("\n", [
    "[Login]",
    "InhibitDelayMaxSec=${var.graceful_shutdown.seconds + 5}",
    "",
  ])

  # The one number both halves of the boot agree on. The bootstrap program is
  # baked into the node image; this says which node.env contract it was written
  # against, and the program refuses to run against any other. Bump both
  # together whenever a key below is added, removed, or changes meaning.
  node_env_contract = 1

  # The program itself, read only so this module can check it declares the same
  # contract number. It is never shipped from here -- the node image bakes it,
  # and this repo is where the image's copy comes from. Reading it is what makes
  # a bump on one side alone a failed plan instead of a failed boot.
  bootstrap_program = file("${path.module}/files/bootstrap.sh")

  # Configuration for the baked bootstrap program, as data. These used to be
  # templatefile() arguments, which rendered a per-node copy of a ~9.6 KB script
  # into user data -- and a genesis node carried three of them, its own plus one
  # inside each worker group's cloud-init in a CAPI bundle. That is what exceeded
  # EC2's 16384-byte decoded user-data limit. The program is the image's business
  # now; only these values are this module's.
  #
  # Every key is always defined (empty where a role does not use it) so the
  # program can run under `set -u`.
  node_config_values = {
    KUBE_COMPUTE_CONTRACT         = tostring(local.node_env_contract)
    NODE_ROLE                     = var.node_role
    CNI                           = var.cni
    CLUSTER_NAME                  = var.cluster_name
    REGISTRATION_ADDRESS          = var.registration_address != null ? var.registration_address : ""
    TRUSTED_CA_ENABLED            = var.trusted_ca_pem != null ? "1" : "0"
    REGISTRY_MIRROR_URL           = var.registry_mirror_url != null ? var.registry_mirror_url : ""
    ISCSI_INITIATOR_ENABLED       = var.iscsi_initiator_enabled ? "1" : "0"
    ISCSI_INITIATOR_LABEL         = coalesce(var.node_fqdn_label, var.node_name)
    DNS_SELF_REGISTER_ZONE        = local.dns_self_register_zone
    DNS_SELF_REGISTER_RECORD_NAME = var.dns_self_register_record_name != null ? var.dns_self_register_record_name : ""
    DNS_SELF_REGISTER_TTL         = tostring(var.dns_self_register_ttl)
    DNS_SERVER_ADDRESS            = var.dns_server_address != null ? var.dns_server_address : ""
    DNS_SERVER_PORT               = tostring(var.dns_server_port)
    NSUPDATE_FLAGS                = local.nsupdate_flags
    TSIG_KEY_NAME                 = var.tsig_key_name != null ? var.tsig_key_name : ""
    TSIG_KEY_ALGORITHM            = var.tsig_key_algorithm
    ARGOCD_NEEDED                 = local.render_argocd ? "1" : "0"
    PLATFORM_APP_ENABLED          = local.platform_app_enabled ? "1" : "0"
    WORKLOADS_APP_ENABLED         = local.workloads_app_enabled ? "1" : "0"
    CAPI_CRD_WAIT_ENABLED         = local.effective_crd_wait_enabled ? "1" : "0"
    CAPI_INSTALL_BAKED            = var.cluster_autoscaler_capi_install_baked ? "1" : "0"
    # Space-separated because the program word-splits it. Every path is composed
    # by this module under /opt/kube-compute/manifests, so none can contain one.
    GENESIS_APPLY_MANIFESTS = join(" ", local.genesis_apply_manifest_paths)
  }

  # Single-quoted with the POSIX '\'' escape, the same way secrets.env is, so
  # any character in a value is safe to embed.
  node_env = join("\n", concat(
    [
      "# SPDX-License-Identifier: Apache-2.0",
      "# Written by kube-compute's node-bootstrap module, read by the bootstrap",
      "# program baked into this image. Configuration only -- tokens and the TSIG",
      "# secret live in secrets.env, which is 0600.",
    ],
    [for k in sort(keys(local.node_config_values)) : "${k}='${replace(local.node_config_values[k], "'", "'\\''")}'"],
    [""],
  ))

  # Everything in config.yaml that is known before this node boots, in the order
  # config.yaml needs it, as one fragment the program appends to the lines only
  # the node itself can produce (its own IP, the fetched agent token, the
  # rejoin-probe result). Assembled here rather than on the node: which blocks a
  # role gets is this module's business, and it keeps the program free of any
  # label, taint or SAN logic.
  #
  # Byte-for-byte what the heredocs in the old rendered script emitted, including
  # the blank lines an empty block leaves behind -- inert in YAML, and worth more
  # than the bytes as proof this change moved the payload without rewriting it.
  config_static = var.node_role == "worker" ? join("\n", [
    local.node_label_block,
    local.node_taint_block,
    local.kubelet_resolv_conf_block,
    "",
    ]) : join("\n", [
    local.static_tls_san_block,
    local.server_static_block,
    local.kubelet_resolv_conf_block,
    "",
  ])

  # Every key is always defined (empty where a role doesn't use it) so
  # bootstrap.sh can run under `set -u` after sourcing it. Single-quoted with
  # the POSIX '\'' escape so any character in a token is safe to embed.
  secret_values = {
    CLUSTER_TOKEN             = var.node_role != "worker" && var.cluster_token != null ? var.cluster_token : ""
    CLUSTER_AGENT_TOKEN       = var.node_role == "server-init" && var.cluster_agent_token != null ? var.cluster_agent_token : ""
    AGENT_TOKEN_FETCH_COMMAND = var.node_role == "worker" && var.agent_token_fetch_command != null ? var.agent_token_fetch_command : ""
    TSIG_KEY_SECRET           = var.tsig_key_secret != null ? var.tsig_key_secret : ""
  }

  secrets_env = join("\n", concat(
    ["# SPDX-License-Identifier: Apache-2.0"],
    [for k in sort(keys(local.secret_values)) : "${k}='${replace(local.secret_values[k], "'", "'\\''")}'"],
    [""],
  ))

  # Every entry is base64-encoded (encoding: b64) — not cosmetic: it makes the
  # outer cloud-config document immune to its own payloads (a PEM, an
  # operator-supplied manifest, a token containing a colon can never break
  # the surrounding YAML), and lets the whole document be safely produced by
  # yamlencode() rather than a text template. Cilium/Argo CD's own manifests
  # are NOT among these entries — kube-image bakes them directly onto the
  # template at /opt/kube-compute/manifests/, and bootstrap.sh reads them
  # from there; embedding Argo CD's ~1.9 MB chart render here is exactly what
  # used to exceed Proxmox's 1 MiB cicustom snippet cap.
  write_files = concat(
    [
      {
        path        = "/opt/kube-compute/secrets.env"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.secrets_env)
      },
      {
        path        = "/opt/kube-compute/node.env"
        permissions = "0644"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.node_env)
      },
      {
        # Always written, even when every block in it is empty: the program cats
        # it unconditionally, and a conditional file would buy nothing but a
        # missing-file branch on the node.
        path        = "/opt/kube-compute/rke2-config-static.yaml"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.config_static)
      },
    ],
    var.trusted_ca_pem == null || var.trusted_ca_in_image ? [] : [{
      path        = "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(var.trusted_ca_pem)
    }],
    var.registry_mirror_url == null ? [] : [{
      path        = "/etc/rancher/rke2/registries.yaml"
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.registries_yaml)
    }],
    !local.kubelet_resolv_conf_enabled ? [] : [{
      path        = local.kubelet_resolv_conf_path
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.kubelet_resolv_conf_content)
    }],
    !local.graceful_shutdown_enabled ? [] : [
      {
        path        = "${local.graceful_shutdown_config_dir}/10-graceful-shutdown.conf"
        permissions = "0644"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.graceful_shutdown_kubelet_config)
      },
      {
        path        = "/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml"
        permissions = "0644"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.graceful_shutdown_arg_block)
      },
      {
        path        = "/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf"
        permissions = "0644"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.graceful_shutdown_logind_config)
      },
    ],
    !(local.render_argocd && local.platform_app_enabled) ? [] : [{
      path        = "/opt/kube-compute/manifests/10-platform-app.yaml"
      permissions = "0600"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.platform_app_yaml)
    }],
    !(local.render_argocd && local.workloads_app_enabled) ? [] : [{
      path        = "/opt/kube-compute/manifests/11-workloads-app.yaml"
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.workloads_app_yaml)
    }],
    [
      # gz+b64, unlike every other file here: a genesis manifest is the one
      # payload large enough to matter against EC2's 25600-byte cap on encoded
      # user data, and a CAPI bundle carries a base64 bootstrap Secret per worker
      # group, which plain b64 would then encode a second time. Only clusters
      # that have genesis manifests are affected, so no existing instance's user
      # data changes.
      for m in local.effective_genesis_apply_manifests : {
        path        = m.path
        permissions = "0600"
        owner       = "root:root"
        encoding    = "gz+b64"
        content     = base64gzip(m.content)
      }
    ],
    !local.is_server ? [] : [
      for name in sort(keys(var.extra_server_manifests)) : {
        path        = "/opt/kube-compute/server-manifests/${name}"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(var.extra_server_manifests[name])
      }
    ],
  )

  # A config.yaml.d drop-in, because only the node itself knows its instance.
  aws_instance_script = <<-EOT
    set -eu
    TOKEN=$(curl -sSf --retry 5 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' http://169.254.169.254/latest/api/token)
    ZONE=$(curl -sSf --retry 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    INSTANCE_ID=$(curl -sSf --retry 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    INSTANCE_TYPE=$(curl -sSf --retry 5 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
    install -d -m 0755 /etc/rancher/rke2/config.yaml.d
    printf 'kubelet-arg+:\n  - "provider-id=aws:///%s/%s"\nnode-label+:\n  - "node.kubernetes.io/instance-type=%s"\n' "$ZONE" "$INSTANCE_ID" "$INSTANCE_TYPE" >/etc/rancher/rke2/config.yaml.d/50-aws-instance.yaml
  EOT

  # Sized on the node from its own memory and cores. Memory is the smaller of EKS's 11 MiB
  # per pod plus 255 MiB, at RKE2's default of 110 pods, and GKE's older tiers of 25% of the
  # first 4 GiB, 20% of the next 4, 10% of the next 8, 6% up to 128 GiB and 2% above, as
  # GKE and AKS now size theirs: kubelet and containerd grow with pods, not with memory.
  # CPU is 6% of the first core, 1% of the second, 0.5% of the next two and 0.25% above.
  # Pods are capped at what is left, so a crowded node evicts or kills pods rather than
  # starving kubelet, containerd and RKE2 until it drops out of the cluster.
  kubelet_reserved_script = <<-EOT
    set -eu
    MEM_MIB=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
    KUBE_MEM_MIB=$(awk -v m="$MEM_MIB" 'BEGIN {
      split("4096 4096 8192 114688", size); split("0.25 0.20 0.10 0.06", share)
      for (i = 1; i <= 4; i++) { t = m < size[i] ? m : size[i]; r += t * share[i]; m -= t }
      r += m * 0.02; p = 11 * 110 + 255
      print int(r < p ? r : p) }')
    KUBE_CPU_M=$(awk -v c="$(nproc)" 'BEGIN {
      print int(60 + (c > 1 ? 10 : 0) + (c > 2 ? (c > 4 ? 2 : c - 2) * 5 : 0) + (c > 4 ? (c - 4) * 2.5 : 0)) }')
    install -d -m 0755 /etc/rancher/rke2/config.yaml.d
    printf 'kubelet-arg+:\n  - "kube-reserved=cpu=%sm,memory=%sMi"\n  - "system-reserved=cpu=100m,memory=256Mi"\n  - "eviction-hard=memory.available<100Mi,nodefs.available<10%%,imagefs.available<15%%,nodefs.inodesFree<5%%,imagefs.inodesFree<5%%"\n' "$KUBE_CPU_M" "$KUBE_MEM_MIB" >/etc/rancher/rke2/config.yaml.d/40-kubelet-reserved.yaml
  EOT

  # RKE2/kubelet default the registered Kubernetes node name to the OS
  # hostname, so every node in a cluster MUST get a distinct value here.
  # var.set_hostname = false omits both keys entirely (see that variable's
  # description) — needed only when this same rendered payload is shared
  # across multiple VMs, e.g. a CAPI MachineDeployment's replicas.
  cloud_config = merge(
    {
      preserve_hostname = false
      # RHEL-family distros (this project's only supported OS) default
      # cloud-init's prefer_fqdn to true, which silently applies the fqdn
      # value below as the actual system hostname even when a distinct
      # short hostname is also given — see Distro._select_hostname in
      # cloud-init's own source. An FQDN-formatted static hostname is
      # exactly what NetworkManager derives its DNS search-domain entry
      # from, which then collides with a wildcard cluster DNS record for
      # that same zone (see kubelet_resolv_conf_block's own comment above
      # for the full failure mode). Forcing the short hostname to win here
      # avoids the collision at its source, for every pod on the node, not
      # just kubelet's.
      prefer_fqdn_over_hostname = false
      write_files               = local.write_files
      runcmd = concat(
        var.aws_provider_id ? [["/bin/sh", "-c", local.aws_instance_script]] : [],
        [["/bin/sh", "-c", local.kubelet_reserved_script]],
        local.graceful_shutdown_enabled ? [["systemctl", "restart", "systemd-logind"]] : [],
        [
          # The program is baked into the image, not written above. An image
          # predating it would otherwise fail with cloud-init's own bare "No such
          # file or directory" against a path this module used to write itself.
          ["/bin/sh", "-c", "test -x /opt/kube-compute/bootstrap.sh || { echo 'kube-compute: this image bakes no /opt/kube-compute/bootstrap.sh, which node.env contract ${local.node_env_contract} requires -- rebuild the node image from a ref that bakes it' >&2; exit 1; }"],
          ["/opt/kube-compute/bootstrap.sh"],
        ],
      )
    },
    var.set_hostname ? { hostname = var.node_name } : {},
    var.set_hostname && var.cluster_fqdn_suffix != null && var.cluster_fqdn_suffix != "" ? {
      fqdn = "${coalesce(var.node_fqdn_label, var.node_name)}.${var.cluster_fqdn_suffix}"
    } : {},
  )

  # "#cloud-config" is a YAML comment, so the whole document — including this
  # required first line — round-trips through any YAML parser unchanged.
  cloud_init_user_data = "#cloud-config\n${yamlencode(local.cloud_config)}"
}
