# node-bootstrap

Renders a `#cloud-config` document for **one node**, given a role already
assigned by the caller (`server-init`, `server-join`, or `worker`). This
module never decides how many nodes exist or which role each gets — that
stays in the provider modules.

## What this module does — and does not do

This module executes nothing and creates no resources of its own. There is no
`null_resource`, no `local-exec`, no connection of any kind to the node, no
Ansible, and no `data.external` Helm render at plan time. Its single
meaningful output is `cloud_init_user_data` — a complete cloud-init document
(hostname, RKE2 `config.yaml`/`registries.yaml`/trusted-CA/manifest payloads
as base64 `write_files`, and a `runcmd` that invokes an on-node bootstrap
script). The caller attaches that output to its VM as user-data; this module
has no resource to `depends_on`.

The heavy half of bootstrap — OS prep, RKE2 binaries, SELinux policy, kernel
modules, the guest agent, **and the genesis Cilium/Argo CD manifests** — is
expected to already be baked into the image the caller boots the VM from (a
"kube-image" template; see its `packer/proxmox/build.sh` and `helm-values/`
for where that render happens). This module only renders the per-cluster
identity, secrets, and join logic that can't be baked into a shared image.
`modules/proxmox-control-plane` and `modules/proxmox-node-pool` are the only
callers currently wired for this — both accept an optional
`proxmox_template_vm_id` to full-clone a pre-baked image, alongside their
older stock-cloud-image paths.

## Cilium/Argo CD are baked, not rendered here

An earlier version of this module shelled out to `helm template` at plan
time (via a `data.external` source) and embedded the rendered manifest whole
in the cloud-init payload. That stopped working for real: Argo CD's chart
alone renders to ~1.9 MB, and Proxmox's `cicustom` snippet upload has a hard
1 MiB cap — a real `tofu apply` against `cluster-1` failed with
`file '...' too long - aborting`. The render moved to kube-image's Packer
build instead (once, at bake time). This module's `render_cilium`/
`render_argocd` locals now only decide whether `bootstrap.sh` applies the
files kube-image already put at
`/opt/kube-compute/manifests/{cilium.yaml,00-argocd.yaml}` on the template —
a per-cluster runtime decision (CNI choice, GitOps enablement), independent
of whether the files exist (they always do, on a kube-image-baked template).

## Watching progress during a real apply

Terraform/OpenTofu returns as soon as the cloud-init payload is attached to
the VM — it has no way to know when (or whether) the node actually joins the
cluster, since nothing in this module executes anything. That all happens
asynchronously on the node, after `apply` has already returned. The node
writes its own progress to `/var/log/kube-compute-bootstrap.log`; that log
is the only place to watch bootstrap progress. There is no Terraform-visible
signal, no provisioner output, and no `bootstrap_log_path`-style output.

## The program is in the image; this module sends it values

`bootstrap.sh` is not rendered here and does not travel in the payload. It lives at
`files/bootstrap.sh`, the node image bakes it at `/opt/kube-compute/bootstrap.sh`,
and this module writes the two files it reads:

- **`node.env`** (0644) — configuration. Every key is always defined, empty where a
  role does not use it, so the program runs under `set -u`.
- **`secrets.env`** (0600) — the join tokens and the TSIG secret, unchanged.

Plus one fragment, `rke2-config-static.yaml`, holding everything in `config.yaml`
knowable before the node boots: labels, taints, extra SANs, the server flags,
kubelet's resolv-conf pointer. Which blocks a role gets is decided here; the program
appends the fragment to the few lines only the node itself can produce (its own IP,
the fetched agent token, the rejoin-probe result).

**Why.** The program is almost entirely static, and a genesis node used to carry it
once for itself and again inside every worker group's cloud-init, against EC2's
16384-byte user-data limit. Shipping values instead of code keeps the payload small on
every platform, with no per-platform side channel.

**The contract.** `node_env_contract` in `main.tf` and `BOOTSTRAP_CONTRACT` in
`files/bootstrap.sh` are the two halves of one number. Bump both together when a key
is added, removed, or changes meaning. Three things enforce it:

- An output precondition here fails the plan if the two disagree in this repo.
- A test asserts the program references every key `node.env` defines.
- The program itself refuses to run against a `node.env` written for another
  contract, so a stale image fails on its first line instead of half-configuring a
  node.

An image newer than the module needs no check: an older module ships its own
rendered copy of the program in `write_files`, which overwrites the baked one. The
failing direction is a module newer than the image, and `runcmd` names it — it tests
the program exists before running it and says what to rebuild.

## Genesis-apply manifests (generic; cluster-autoscaler is the one caller today)

This module no longer knows anything about cluster-autoscaler, CAPI, or
CAPMOX specifically. It exposes two generic inputs instead:

- `genesis_apply_manifests` — an ordered list of `{path, content}` entries,
  written verbatim under `/opt/kube-compute/manifests/` via `write_files` and
  `kubectl apply -f`'d in order by `bootstrap.sh`. This module does not
  interpret `content` at all.
- `cluster_autoscaler_crd_wait_enabled` — gates a `bootstrap.sh` block that
  waits for cert-manager's CRDs (installed by the platform Argo CD
  Application, applied just before this block), applies the kube-image-baked
  `capi-install.yaml` (CAPI core + CAPMOX manifests — their webhook TLS is
  provisioned via cert-manager `Issuer`/`Certificate` objects, a hard
  dependency), and waits for CAPI's own core CRDs to be `Established`
  **before** applying the `genesis_apply_manifests` entries. Despite the
  name, it is not cluster-autoscaler-specific — any caller needing CAPI's
  CRDs to exist first can use it.

Both are genesis-only (`server-init` only). `genesis_apply_manifests` itself
has no opinion on `gitops_platform_enabled`. `cluster_autoscaler_crd_wait_enabled`
is different: it is NOT independent of `gitops_platform_enabled` — cert-manager
only exists on this cluster because the platform Argo CD Application installs
it, so setting this true with `gitops_platform_enabled = false` leaves
`capi-install.yaml` with no way to ever succeed. `proxmox-cluster` (the one
caller today) enforces this with its own
`cluster_autoscaler_requires_platform_gitops` precondition.

The one real caller today is `modules/proxmox-cluster`, which owns the
`cluster_autoscaler_enabled` toggle and everything cluster-autoscaler-specific:
it renders a `Cluster` + `Secret` (containing this same module's own shared
worker `cloud_init_user_data`, via a second `node_bootstrap` instantiation
with `set_hostname = false`) + `ProxmoxMachineTemplate` + `MachineDeployment`
bundle (see that module's README/`templates/cluster-autoscaler-workers.yaml.tftpl`),
passes it in as a single `genesis_apply_manifests` entry, and sets
`cluster_autoscaler_crd_wait_enabled = var.cluster_autoscaler_enabled`. There
is deliberately no `RKE2ConfigTemplate`/CAPRKE2 in that bundle — workers join
via a plain `Secret` referenced by `Machine.spec.bootstrap.dataSecretName`,
reusing this project's existing worker cloud-init logic.

`proxmox-cluster` also merges a `clusterAutoscalerEnabled` Helm parameter
into `platform_extra_helm_parameters` before it reaches this module — that
gates kube-platform's own `cluster-autoscaler` Argo CD Application so it only
syncs on clusters that opted in. This module has no hardcoded knowledge of
that parameter; it's just another entry in the generic
`platform_extra_helm_parameters` map.

## `set_hostname` (for shared, byte-identical cloud-init payloads)

Every caller gets `set_hostname = true` (the default): `hostname`/`fqdn` are
written into cloud-config from `node_name`, required because RKE2/kubelet
registers the node by OS hostname. `set_hostname = false` omits both keys
entirely — the only reason to do this is when the exact same rendered
`cloud_init_user_data` is shared across multiple VMs that cannot each get
their own render (e.g. every replica of a CAPI `MachineDeployment`, via one
Secret referenced by `dataSecretName`). The VM platform's own per-instance
metadata (e.g. CAPMOX/cloud-init's NoCloud `local-hostname`) is relied on
instead to supply a unique hostname — **this specific assumption is
unverified against real hardware**, flagged explicitly as a first
real-cluster check for any `set_hostname = false` caller.

## `aws_provider_id`

Registers the node with providerID `aws:///<zone>/<instance-id>` and labels it
`node.kubernetes.io/instance-type`, written as an RKE2 `config.yaml.d` drop-in from
instance metadata before the bootstrap program starts RKE2. cluster-autoscaler and
the AWS cloud controller manager find a node's instance through the providerID. The
label is otherwise set by a cloud controller manager's node controller, which RKE2's
is not here (`disable-cloud-controller`) and kube-platform's AWS one does not run.
Off by default, since turning it on changes the payload and so replaces existing
nodes.

## Resources reserved for the node

Every node reserves CPU and memory for kubelet, containerd, RKE2 and the OS, so pods
can never take all of it. Without a reservation a crowded node doesn't evict pods: it
reclaims memory until containerd stops answering kubelet and the node goes NotReady.
The node sizes the reservation from its own memory and cores and writes it as an RKE2
`config.yaml.d` drop-in before RKE2 starts. Memory follows EKS's per-pod formula, capped
by GKE's older tiers as GKE and AKS now do, since kubelet and containerd grow with the
number of pods rather than with the node's memory:

| | Reserved |
|---|---|
| `kube-reserved` memory | 11 MiB per pod plus 255 MiB at RKE2's default of 110 pods (1465 MiB), or 25% of the first 4 GiB, 20% of the next 4, 10% of the next 8, 6% up to 128 GiB and 2% above, whichever is smaller |
| `kube-reserved` CPU | 6% of the first core, 1% of the second, 0.5% of the next two, 0.25% above |
| `system-reserved` | 100m CPU, 256 MiB |
| `eviction-hard` | `memory.available<100Mi`, plus kubelet's own disk and inode defaults, which the flag would otherwise drop |

An 8 GiB node, for example, keeps about 5.8 GiB for pods and a 16 GiB node about 13.7 GiB.

The control plane runs as static pods, so server nodes give them requests through
`control-plane-resource-requests` (kube-apiserver 1024Mi, etcd 512Mi,
kube-controller-manager 256Mi, kube-scheduler 128Mi) and the scheduler counts their
memory instead of the reservation having to cover it.

## Graceful shutdown

`graceful_shutdown` gives kubelet a window to evict pods when the OS is shutting
down, so a node that is stopped or terminated stops its workloads instead of having
them killed with it. Three files carry it, all written before RKE2 starts:

| File | Why |
|---|---|
| `/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf` | `shutdownGracePeriod` and `shutdownGracePeriodCriticalPods` |
| `/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml` | `kubelet-arg` cannot set either — they have no command-line flag — so kubelet is given `config-dir` and reads the drop-in above |
| `/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf` | `InhibitDelayMaxSec`, five seconds by default, is the longest logind lets kubelet hold the shutdown. Left alone it silently caps the grace period to five seconds |

`runcmd` restarts `systemd-logind` so the last of those applies to the node's first
shutdown, not just later ones. The total must stay under whatever the platform allows
an instance before it cuts the power — about two minutes on AWS — and must leave room
for the longest `terminationGracePeriodSeconds` among the pods that land here. Null
disables all of it.

## Interface notes

- `ansible_playbook_path`, `invocation_mode`, `ansible_connection_vars`,
  `on_node_bundle`, `on_node_secret_env`, `node_provider`, `bootstrap_id`,
  `cilium_version`, `argocd_version`, and `cilium_operator_replicas` are all
  gone. There is no playbook, no `null_resource`, no on-node bundle, no
  provider branching, and no Helm render in this module — the two version
  variables had no effect once kube-image took over the render (both are
  baked into the template, resolved from kube-platform's
  `platform-versions.yaml` at build time), and `cilium_operator_replicas` had
  nowhere left to reach once the render was no longer per-cluster
  (kube-platform's own `cilium-app.yaml` hardcodes `replicas: 1` and
  overwrites any genesis-time value on Argo CD's first `selfHeal` anyway).
- `cni` defaults to `"cilium"` (eBPF dataplane, no iptables/ipset/xtables
  dependency — the only variant verified against AlmaLinux 10). When
  `cni = "cilium"` on a genesis node, the module has `bootstrap.sh` apply the
  Cilium manifest kube-image already baked onto the template, and sets
  `disable: [rke2-cilium]` in `config.yaml` so RKE2's own built-in HelmChart
  install of Cilium never runs alongside it. `"default"` remains selectable
  only as an escape hatch for a consumer-supplied image/template that ships a
  different CNI out of the box.
- `cluster_token`/`cluster_agent_token`/`agent_token_fetch_command`/
  `trusted_ca_pem`/`tsig_key_secret` are all `sensitive = true` and flow only
  into the cloud-init payload's base64-encoded `write_files` (a 0600
  `/opt/kube-compute/secrets.env`, sourced by the bootstrap script) — never
  as plaintext Terraform state elsewhere, never over any inbound connection.
  `server-join` receives `cluster_token` the same direct way `server-init`
  does; only `worker` uses the fetch-command pattern, since a worker joins an
  already-existing cluster and pulls its token from the provider's own
  secret store instead.
- `modules/aws-control-plane` and `modules/aws-node-pool` are also cut over to
  this interface: both call this module with no
  `node_provider`/`ansible_playbook_path`/`ansible_connection_vars` and attach
  `cloud_init_user_data` via AWS's own `user_data_base64 = base64gzip(...)`
  convention, combined via a cloud-init MIME multipart document with a small
  AWS-only SSM-agent-enable script (see those modules' own `main.tf`/README
  for why the MIME combine lives there, not here). `aws-node-pool`'s ASG
  launch template calls this module with `set_hostname = false` since every
  pool member shares one rendered payload — same pattern as
  `proxmox-cluster`'s cluster-autoscaler workers.
  `modules/azure-control-plane`/`modules/azure-node-pool` no longer exist as
  working code — reduced to placeholders (their prior implementation called
  this module's pre-cutover interface and was never validated against real
  Azure infrastructure). A future Azure implementation should call this
  module's current interface directly rather than resurrect the old one.
