# SPDX-License-Identifier: Apache-2.0
# node-bootstrap renders a lean cloud-init payload. It executes NOTHING: no
# null_resource, no local-exec, no Ansible, no connection to the node. The
# heavy half of RKE2 bootstrap (OS prep, RKE2 binaries, SELinux policy, kernel
# modules, guest agent) is baked into a kube-images template; what's left here
# is per-cluster identity, secrets, and join logic — what can't be baked into
# a shared image.
locals {
  # The kube-platform pin, held here and not in the gitops_platform_repo_url/_revision
  # variable defaults: an explicit null or "" passed through a module call does not
  # fall through to a variable default. coalesce() treats null and "" alike, and
  # tests/platform_pin.tftest.hcl locks that in. The pin tracks kube-platform's
  # protected `main` branch, not a SHA.
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

  is_server = contains(["server-init", "server-join"], var.node_role)
  is_init   = var.node_role == "server-init"
  is_join   = var.node_role == "server-join"
  is_agent  = var.node_role == "worker"

  # Whether bootstrap.sh applies the Cilium manifest and the Argo CD manifest. It
  # takes both from bootstrap/rendered/ in a clone of the platform ref. This module
  # renders neither: Argo CD is too big for Proxmox's 1 MiB cicustom snippet cap.
  render_cilium = var.node_role == "server-init"
  render_argocd = local.argocd_needed && var.node_role == "server-init"

  # The genesis node clones the platform ref when it needs either manifest. With
  # gitops_platform_enabled = false the pinned repo is not used: the caller names the
  # repo, because a cluster that opted out of the platform should not silently
  # fetch from the public default. An empty URL fails the precondition on the outputs.
  platform_clone_needed = local.render_cilium || local.render_argocd
  boot_platform_repo_url = !local.platform_clone_needed ? "" : (
    var.gitops_platform_enabled ? local.effective_gitops_platform_repo_url : (
      var.gitops_platform_repo_url != null ? var.gitops_platform_repo_url : ""
    )
  )
  boot_platform_revision = local.platform_clone_needed ? local.effective_gitops_platform_revision : ""

  # Rendered by yamlencode() here, not on the node — keeps the node free of
  # any templating engine. Both Argo CD Applications are built as objects and
  # encoded, so a caller's value can hold any character without changing the
  # structure around it.
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

  # Multi-source Application: the second source (ref: values, no chart)
  # makes platform-versions/values.yaml available to the first source's
  # `helm.valueFiles`, so bootstrap's chart templates (cilium-app.yaml,
  # argocd-app.yaml) can read .Values.ciliumVersion/.Values.argocdVersion at
  # every sync — same mechanism system-upgrade-plans-app.yaml uses for
  # .Values.k8sVersion. This is what makes bumping platform-versions/values.yaml
  # alone enough to roll Cilium/Argo CD forward kube-platform-wide, with no
  # per-cluster apply and no editing the Application templates themselves.
  platform_helm_parameters = concat(
    [
      { name = "platformRepoURL", value = local.effective_gitops_platform_repo_url },
      { name = "platformRevision", value = local.effective_gitops_platform_revision },
      { name = "certMode", value = var.cert_mode },
      { name = "clusterName", value = var.cluster_name },
      { name = "clusterFqdnSuffix", value = var.cluster_fqdn_suffix != null ? var.cluster_fqdn_suffix : "" },
      { name = "trustedCaPemB64", value = base64encode(var.trusted_ca_pem != null ? var.trusted_ca_pem : "") },
    ],
    local.workloads_app_enabled ? [
      { name = "workloadsRepoURL", value = local.effective_gitops_workloads_repo_url },
      { name = "workloadsRevision", value = var.gitops_workloads_revision },
      { name = "workloadsPath", value = var.gitops_workloads_path },
    ] : [],
    [for name, val in var.platform_extra_helm_parameters : { name = name, value = val }],
  )

  platform_app = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata   = { name = "platform", namespace = "argocd" }
    spec = {
      project = "default"
      sources = [
        {
          repoURL        = local.effective_gitops_platform_repo_url
          targetRevision = local.effective_gitops_platform_revision
          path           = "bootstrap"
          helm = {
            valueFiles   = ["$values/platform/platform-versions/values.yaml"]
            parameters   = local.platform_helm_parameters
            valuesObject = local.platform_values_object
          }
        },
        {
          repoURL        = local.effective_gitops_platform_repo_url
          targetRevision = local.effective_gitops_platform_revision
          ref            = "values"
        },
      ]
      destination = local.argocd_app_destination
      syncPolicy  = local.argocd_app_sync_policy
    }
  }

  platform_app_yaml = yamlencode(local.platform_app)

  argocd_app_destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
  argocd_app_sync_policy = {
    automated   = { prune = true, selfHeal = true }
    syncOptions = ["CreateNamespace=true"]
  }

  # Deliberately independent of the platform Application: no shared app-of-apps
  # parent, no sync-wave ordering against it. Eventual consistency — if a
  # workload needs something platform provides, Argo CD's own automated
  # selfHeal/retry converges it once platform catches up.
  workloads_helm = merge(
    length(var.workloads_extra_helm_parameters) > 0 ? {
      parameters = [for name, val in var.workloads_extra_helm_parameters : { name = name, value = val }]
    } : {},
    var.workloads_helm_values_object != null ? { valuesObject = local.workloads_values_object } : {},
  )

  workloads_app = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata   = { name = "workloads", namespace = "argocd" }
    spec = {
      project = "default"
      source = merge(
        {
          repoURL        = local.effective_gitops_workloads_repo_url
          targetRevision = var.gitops_workloads_revision
          path           = var.gitops_workloads_path
        },
        local.workloads_helm_configured ? { helm = local.workloads_helm } : {},
        local.workloads_helm_configured ? {} : { directory = { recurse = true } },
      )
      destination = local.argocd_app_destination
      syncPolicy  = local.argocd_app_sync_policy
    }
  }

  workloads_app_yaml = yamlencode(local.workloads_app)

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
    # Likewise, the scheduler and controller manager listen on 127.0.0.1 by
    # default, where kube-platform's Prometheus can't scrape them (it reaches
    # these host-network pods at the node IP), so their dashboards are empty
    # and their TargetDown/InstanceUnreachable alerts fire on every cluster.
    # Both ports (10259, 10257) are HTTPS and need an authorized token for
    # /metrics; only the health endpoints are open, as on loopback.
    "kube-scheduler-arg:",
    "  - \"bind-address=0.0.0.0\"",
    "kube-controller-manager-arg:",
    "  - \"bind-address=0.0.0.0\"",
    # The control plane runs as static pods on the node. With requests the scheduler
    # counts its memory; the node reservation below covers only what runs outside pods.
    "control-plane-resource-requests: \"kube-apiserver-cpu=250m,kube-apiserver-memory=1024Mi,etcd-cpu=200m,etcd-memory=512Mi,kube-controller-manager-cpu=200m,kube-controller-manager-memory=256Mi,kube-scheduler-cpu=100m,kube-scheduler-memory=128Mi\"",
    ], var.control_plane_taint ? [
    "node-taint:",
    "  - \"CriticalAddonsOnly=true:NoExecute\"",
    ] : [], [
    "cni: cilium",
    "disable-kube-proxy: true",
    # Without this, RKE2 installs its own bundled rke2-cilium addon (a separate
    # HelmChart CR) alongside the genesis-rendered Cilium manifest — both
    # fighting over the same cilium-operator/cilium objects in kube-system.
    "disable:",
    "  - rke2-cilium",
  ]))

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
  # the cluster's own wildcard IP instead of the real host, and a clone of
  # github.com fails with connection refused. Pointing kubelet at a
  # search-domain-free resolv.conf (var.dns_servers only, no `search` line) fixes
  # every pod on the node, without touching the node's own OS resolv.conf.
  # Used only when var.dns_servers is set.
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

  # Where a server-init node looks for a live cluster before it starts etcd.
  # Explicit addresses win; otherwise registration_address, as before.
  rejoin_probe_addresses = (
    length(var.rejoin_probe_addresses) > 0 ? var.rejoin_probe_addresses :
    var.node_role == "server-init" && var.registration_address != null ? [var.registration_address] : []
  )

  # A joining server is a server-join node, or a server-init node that can find a live
  # cluster at boot and become one.
  can_rejoin    = local.is_init && length(local.rejoin_probe_addresses) > 0
  joins_cluster = local.is_join || local.can_rejoin

  # The steps of the boot program, in the order they run. A step is in the program only
  # when it applies to this node. Every file in files/steps must be listed here, and
  # tests/boot_steps.tftest.hcl verifies that.
  boot_step_catalog = [
    { name = "prelude", file = "00-prelude.sh", enabled = true },
    { name = "skew-check", file = "01-skew-check.sh", enabled = local.is_server },
    { name = "rejoin-probe", file = "10-rejoin-probe.sh", enabled = local.can_rejoin },
    { name = "node-config-server", file = "20-node-config-server.sh", enabled = local.is_server },
    { name = "node-config-agent", file = "20-node-config-agent.sh", enabled = local.is_agent },
    { name = "platform-clone", file = "30-platform-clone.sh", enabled = local.platform_clone_needed },
    { name = "api-skew-check", file = "31-api-skew-check.sh", enabled = local.joins_cluster },
    { name = "genesis-cilium-manifest", file = "40-genesis-cilium-manifest.sh", enabled = local.render_cilium },
    { name = "genesis-extra-manifests", file = "41-genesis-extra-manifests.sh", enabled = local.is_init && length(var.extra_server_manifests) > 0 },
    { name = "start-server-init", file = "50-start-server-init.sh", enabled = local.is_init },
    { name = "start-server-join", file = "51-start-server-join.sh", enabled = local.joins_cluster },
    { name = "start-agent", file = "52-start-agent.sh", enabled = local.is_agent },
    { name = "wait-ready-server", file = "60-wait-ready-server.sh", enabled = local.is_server },
    { name = "wait-ready-agent", file = "61-wait-ready-agent.sh", enabled = local.is_agent },
    { name = "genesis-cilium-handoff", file = "70-genesis-cilium-handoff.sh", enabled = local.render_cilium },
    { name = "genesis-argocd", file = "71-genesis-argocd.sh", enabled = local.render_argocd },
    { name = "finish", file = "99-finish.sh", enabled = true },
  ]

  # tflint-ignore: terraform_unused_declarations # read by tests/boot_steps.tftest.hcl
  boot_step_files_on_disk = fileset("${path.module}/files/steps", "*.sh")

  boot_steps_enabled = [for step in local.boot_step_catalog : step if step.enabled]

  bootstrap_program = join("", [for step in local.boot_steps_enabled : file("${path.module}/files/steps/${step.file}")])

  # The program as it travels in user data. Lines whose first non-blank character
  # is "#" are dropped, except the shebang. This is safe only while no heredoc body
  # line starts with "#"; tests/bootstrap_inline.tftest.hcl enforces that.
  bootstrap_program_inline = replace(local.bootstrap_program, "/(?m)^[ \t]*#([^!\n][^\n]*)?\n/", "")

  platform_required_files = concat(
    local.render_cilium ? ["bootstrap/rendered/cilium.yaml"] : [],
    local.render_argocd ? ["bootstrap/rendered/argocd.yaml"] : [],
  )

  # Configuration for the bootstrap program, as data.
  #
  # Every key is always defined (empty where a role does not use it) so the
  # program can run under `set -u`.
  node_config_values = {
    NODE_ROLE            = var.node_role
    REGISTRATION_ADDRESS = var.registration_address != null ? var.registration_address : ""
    # Space-separated because the program word-splits it. Addresses are IPs or
    # FQDNs, so none can contain one.
    REJOIN_PROBE_ADDRESSES  = join(" ", local.rejoin_probe_addresses)
    PLATFORM_REPO_URL       = local.boot_platform_repo_url
    PLATFORM_REVISION       = local.boot_platform_revision
    PLATFORM_REQUIRED_FILES = join(" ", local.platform_required_files)
    PLATFORM_APP_ENABLED    = local.platform_app_enabled ? "1" : "0"
    WORKLOADS_APP_ENABLED   = local.workloads_app_enabled ? "1" : "0"
    # Empty when no CA is set.
    TRUSTED_CA_FILE = local.trusted_ca_present ? local.trusted_ca_path : ""
  }

  # Single-quoted with the POSIX '\'' escape, the same way secrets.env is, so
  # any character in a value is safe to embed.
  node_env = join("\n", concat(
    [
      "# SPDX-License-Identifier: Apache-2.0",
      "# Written by kube-compute's node-bootstrap module, read by the bootstrap",
      "# program. Configuration only.",
    ],
    [for k in sort(keys(local.node_config_values)) : "${k}='${replace(local.node_config_values[k], "'", "'\\''")}'"],
    [""],
  ))

  # The RKE2 config known at plan time, written to /etc/rancher/rke2/config.yaml by
  # cloud-init. What only the node knows (its own IP, the rejoin result, the fetched
  # agent token) goes into a drop-in at boot. Tokens are JSON strings, which is valid
  # YAML: a token that starts with "*" would otherwise be read as an alias.
  #
  # An empty block leaves a blank line behind. It is inert in YAML.
  join_server_line = var.registration_address != null ? "server: https://${var.registration_address}:9345" : ""
  tls_san_section  = local.static_tls_san_block == "" ? "" : "tls-san:\n${local.static_tls_san_block}"

  rke2_config = local.is_agent ? join("\n", [
    local.join_server_line,
    local.node_label_block,
    local.node_taint_block,
    local.kubelet_resolv_conf_block,
    "",
    ]) : join("\n", [
    local.is_join ? local.join_server_line : "",
    var.cluster_token != null ? "token: ${jsonencode(var.cluster_token)}" : "",
    local.is_init && var.cluster_agent_token != null ? "agent-token: ${jsonencode(var.cluster_agent_token)}" : "",
    local.tls_san_section,
    local.server_static_block,
    local.kubelet_resolv_conf_block,
    "",
  ])

  # Worker only. The fetch command can hold a literal token, so the file is 0600.
  secrets_env = join("\n", [
    "# SPDX-License-Identifier: Apache-2.0",
    "AGENT_TOKEN_FETCH_COMMAND='${replace(var.agent_token_fetch_command != null ? var.agent_token_fetch_command : "", "'", "'\\''")}'",
    "",
  ])

  # Every entry is base64-encoded (encoding: b64) — not cosmetic: it makes the
  # outer cloud-config document immune to its own payloads (a PEM, an
  # operator-supplied manifest, a token containing a colon can never break
  # the surrounding YAML), and lets the whole document be safely produced by
  # yamlencode() rather than a text template. Cilium/Argo CD's own manifests
  # are NOT among these entries: bootstrap.sh reads them from a clone of the
  # platform ref. Embedding Argo CD's ~2 MB manifest here would exceed Proxmox's
  # 1 MiB cicustom snippet cap.
  write_files = concat(
    [
      {
        path        = "/opt/kube-compute/node.env"
        permissions = "0644"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.node_env)
      },
      {
        path        = "/opt/kube-compute/bootstrap.sh"
        permissions = "0755"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.bootstrap_program_inline)
      },
      {
        path        = "/etc/rancher/rke2/config.yaml"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.rke2_config)
      },
    ],
    !local.is_agent ? [] : [{
      path        = "/opt/kube-compute/secrets.env"
      permissions = "0600"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.secrets_env)
    }],
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
    !local.is_init ? [] : [
      for name in sort(keys(var.extra_server_manifests)) : {
        path        = "/opt/kube-compute/server-manifests/${name}"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(var.extra_server_manifests[name])
      }
    ],
    [
      for file in var.provider_files : {
        path        = file.path
        permissions = file.permissions
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(file.content)
      }
    ],
  )

  trusted_ca_path = "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"

  # Not sensitive: whether a CA is set says nothing about it, and it decides which steps run.
  trusted_ca_present = nonsensitive(var.trusted_ca_pem != null)

  # A CA that the image bakes is not in user data, so the guard names the cause when it
  # is missing: containerd's TLS pin in registries.yaml points at this file.
  # runcmd does not stop at a failed command, so a failure leaves a marker file and the boot
  # program stops on it.
  trusted_ca_command = [
    "/bin/sh", "-c",
    join("; ", concat(
      var.trusted_ca_in_image ? ["test -s ${local.trusted_ca_path} || { echo 'kube-compute: no trusted CA at ${local.trusted_ca_path}: trusted_ca_in_image is set and the image does not bake one' >&2; touch /run/kube-compute-step-failed; exit 1; }"] : [],
      ["update-ca-trust extract || { echo 'kube-compute: update-ca-trust failed' >&2; touch /run/kube-compute-step-failed; exit 1; }"],
    )),
  ]

  # The cloud-init commands that run before the boot program, in order. The provider
  # modules supply the first ones.
  commands_before_boot = concat(
    var.provider_steps,
    [{ name = "kubelet-reserved", commands = [["/bin/sh", "-c", local.kubelet_reserved_script]] }],
    local.trusted_ca_present ? [{ name = "trusted-ca", commands = [local.trusted_ca_command] }] : [],
    local.graceful_shutdown_enabled ? [{ name = "graceful-shutdown", commands = [["systemctl", "restart", "systemd-logind"]] }] : [],
  )

  commands_after_boot = var.os_auto_updates ? [{ name = "os-auto-updates", commands = [["/bin/sh", "-c", local.os_auto_updates_script]] }] : []

  # Every step of this node's boot, in the order it runs.
  boot_steps = concat(
    [for step in local.commands_before_boot : step.name],
    [for step in local.boot_steps_enabled : step.name],
    [for step in local.commands_after_boot : step.name],
  )

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

  # This runs after the boot program. The marker makes a failed boot fail this command too,
  # so cloud-init does not report success for a node that did not join.
  os_auto_updates_script = <<-EOT
    set -eu
    test -e /run/kube-compute-boot-complete || { echo 'kube-compute: the boot program did not complete' >&2; exit 1; }
    dnf install -y dnf-automatic yum-utils
    dnf config-manager --save --setopt=excludepkgs=rke2-server,rke2-agent,rke2-common
    install -d -m 0755 /etc/systemd/system/dnf-automatic-install.timer.d
    printf '[Timer]\nOnBootSec=15min\n' >/etc/systemd/system/dnf-automatic-install.timer.d/10-on-boot.conf
    systemctl daemon-reload
    systemctl enable --now dnf-automatic-install.timer
  EOT

  # RKE2/kubelet default the registered Kubernetes node name to the OS
  # hostname, so every node in a cluster MUST get a distinct value here.
  # var.set_hostname = false omits both keys entirely (see that variable's
  # description) — needed only when this same rendered payload is shared
  # across multiple VMs, e.g. a scale set's replicas.
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
        concat([], [for step in local.commands_before_boot : step.commands]...),
        [["/opt/kube-compute/bootstrap.sh"]],
        concat([], [for step in local.commands_after_boot : step.commands]...),
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
