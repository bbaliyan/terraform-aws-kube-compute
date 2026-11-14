# node-bootstrap

Renders a `#cloud-config` document for **one node**, given a role already
assigned by the caller (`server-init`, `server-join`, or `worker`). This
module never decides how many nodes exist or which role each gets — that
stays in the provider modules.

## What this module does — and does not do

This module executes nothing and creates no resources of its own. There is no
`null_resource`, no `local-exec`, no connection of any kind to the node, no
Ansible, and no `data.external` Helm render at plan time. `cloud_init_user_data`
is a complete cloud-init document (hostname, RKE2
`config.yaml`/`registries.yaml`/trusted-CA/manifest payloads as base64
`write_files`, and a `runcmd` that invokes an on-node bootstrap script). The
caller attaches the `cloud_init_user_data` output to its VM; this module has no resource
to `depends_on`.

## User data

`cloud_init_user_data` is the final user data of the node. It is a plain `#cloud-config` document.

The image must already hold OS prep, the RKE2 binaries, the SELinux policy, the kernel
modules and the guest agent. It must also hold these tools: git, curl, getent, ip, awk,
systemctl and update-ca-trust. Build it with kube-images. The image holds neither Cilium
nor Argo CD: the first server reads both from the platform ref (see below). This module
renders only the per-cluster identity, secrets and join logic. Every provider module calls
it: `aws-control-plane`, `aws-static-node`, `aws-node-pool`, `proxmox-control-plane` and
`proxmox-node-pool`.

## Cilium and Argo CD come from the platform ref

The first server needs two manifests that are too big for the cloud-init payload:
Cilium and Argo CD. It reads both from the platform repo, so one value picks the
version of both: `gitops_platform_repo_url` at `gitops_platform_revision`. This is the
same ref that the platform Application syncs.

On the first server, before RKE2 starts, the boot program does these steps:

1. It checks that the image has the tools listed above. If tools are missing, it names all of them in one message and stops.
2. It clones the platform ref into `/run/platform-ref`. It tries 5 times, 5 seconds apart.
   - For a branch or a tag, it runs `git clone --depth 1 --branch`.
   - For a 40-digit hex commit, it runs `git clone --filter=blob:none --no-checkout` and then `git checkout`.
3. If `bootstrap/rendered/cilium.yaml` or `bootstrap/rendered/argocd.yaml` is missing, it stops with one line that names the repo, the ref and the path.
4. It reads `k8sVersion` from `platform/platform-versions/values.yaml`. If the minor version of the RKE2 in the image is newer, it stops. A newer patch of the same minor version is fine.
5. On the first server, it copies `cilium.yaml` into the RKE2 manifests directory.
6. After the node is Ready and CoreDNS is up, it applies `argocd.yaml` with server-side apply.
7. It waits for the Argo CD workloads to roll out.

Each failure stops the boot and is written to `/var/log/kube-compute-bootstrap.log`.
The node needs a route to the repo at first boot, and the repo must be readable without
credentials. A joining server or a worker clones nothing.

A joining server also compares its image's RKE2 with the version that the API server
reports at `/version`. It stops if the minor version of the image is newer. It skips the comparison when the
API server does not answer. A worker does not compare.

If `gitops_platform_enabled` is false, the module does not fall back to the pinned repo.
Set `gitops_platform_repo_url` when the first server needs Cilium or Argo CD. If it is not
set, the plan fails with a message that names the input. The pinned default
(`kube-platform` at `main`) applies only while the platform Application is enabled.

### Upgrade order

A first server probes `REJOIN_PROBE_ADDRESSES` for a live cluster before it starts etcd
(the `rejoin_probe_addresses` input). If it finds one, it becomes a joining server. It
skips Cilium, the extra server manifests, Argo CD and the Applications.

1. Rebuild the node image with git, and without a baked Cilium or Argo CD manifest.
2. Move the module to the new version.

The first server removes the copied `cilium.yaml` from the RKE2 manifests directory after
Cilium is Ready. RKE2 applies every file in that directory again on each start. Without
the removal, a restart would put the boot Cilium back after the platform upgraded it.
Removing the file does not remove Cilium from the cluster. If Cilium is not Ready within
about 6 minutes, the file stays and the log shows a warning. The first server removes the
file even when GitOps is off.

Existing clusters do not change until a node is replaced.

## Watching progress

Terraform/OpenTofu returns as soon as the cloud-init payload is attached to the VM. It has
no way to know when (or whether) the node actually joins the cluster, since nothing in
this module executes anything. That all happens asynchronously on the node, after `apply`
has already returned. The node writes its own progress to
`/var/log/kube-compute-bootstrap.log`; that log is the only place to watch bootstrap
progress. There is no Terraform-visible signal, no provisioner output, and no
`bootstrap_log_path`-style output.

## The program travels in user data

The boot program is a list of step files in `files/steps/`. The module lists them in
`boot_step_catalog`, each with the condition that selects it. It joins the steps that
apply to the node's role and writes the result to `/opt/kube-compute/bootstrap.sh`
(0755) as one `write_files` entry. `runcmd` runs it. A step that does not apply to the
role is never in the file:

- Core steps depend on the role. A server runs `node-config-server`, the start and wait
  steps for servers and the skew check. An agent runs `node-config-agent`, `start-agent`
  and `wait-ready-agent`.
- Genesis steps (`platform-clone`, `genesis-cilium-manifest`, `genesis-cilium-handoff`,
  `genesis-argocd`, `genesis-extra-manifests`) are in the program only on the first
  server, and only when the feature is on.
- Provider steps are not here. The provider modules pass them in `provider_steps` and
  `provider_files`. These are DNS self-registration and the iSCSI initiator name on
  Proxmox, and SSM Agent and the provider ID on AWS.

The `boot_steps` output lists every step in the order it runs. The provider modules
assert the exact list in their tests, so a step of one provider cannot reach the other.

The module removes the comment lines first, to save space. A line whose first non-blank
character is `#` is dropped, except the shebang. A step must use no heredoc, because a
body line that starts with `#` would be dropped. A test fails if a step has one.

The module also writes the files the program reads:

- **`/etc/rancher/rke2/config.yaml`** (0600) — the RKE2 config known at plan time. It
  holds the join server and tokens, labels, taints, extra SANs, the server flags and
  kubelet's resolv-conf pointer. cloud-init writes it. The program adds only what the node
  alone knows, as the drop-in `config.yaml.d/20-node.yaml`. That is its own IP, the server
  that the rejoin probe found and, on an agent, the fetched token.
- **`node.env`** (0644) — configuration for the program. Every key is always defined,
  empty where a role does not use it, so the program runs under `set -u`.
- **`secrets.env`** (0600), on an agent only — the agent token fetch command. The
  program deletes it when the boot succeeds. If the boot fails, it stays for diagnosis.

The trusted CA is a `write_files` entry and a `runcmd` entry (`update-ca-trust extract`).
There is no registry mirror check at boot.

EC2 limits user data to 16384 bytes after gzip. A test renders a heavy AWS genesis
node and asserts it stays at least 1024 bytes under that limit.

## Workloads repo parameters on the `platform` Application

If `gitops_workloads_repo_url` is set, the `platform` Application gets three more Helm parameters:

- `workloadsRepoURL`, from `gitops_workloads_repo_url`.
- `workloadsRevision`, from `gitops_workloads_revision`.
- `workloadsPath`, from `gitops_workloads_path`.

If `gitops_workloads_repo_url` is not set, the Application has none of them and renders as before. kube-platform treats a missing parameter as empty.

The module writes the `platform` Application at first boot. An existing cluster gets these parameters only when its node is rebuilt. See "A change to the user data of a running node".

## A change to the user data of a running node

This module renders the user data. Its callers decide what a change does to a node that already runs. Every input of this module is in the user data, so a change to any of them is a user data change. So is a module upgrade that changes the render.

cloud-init reads the user data only at the first boot. A running node never applies a change to it.

The control-plane modules (`aws-control-plane`, `proxmox-control-plane`) and `aws-static-node` treat a change the same way on both providers: the node keeps running. On AWS, the instance keeps the user data it booted with. On Proxmox, the snippet on storage gets the new content, but the VM is not replaced.

To apply a change to a node, replace that node on purpose with `tofu apply -replace='<address>'`.

`aws-node-pool` (an Auto Scaling group) and `proxmox-node-pool` work the same way for running nodes. An Auto Scaling group gives new user data only to the instances it launches later.

### Replace a node on purpose

> **Warning:** Replacing a single-node cluster loses the cluster. Replace one control-plane node at a time, and the first node last, in its own apply.

1. Find the address of the node with `tofu state list`. Examples: `module.<name>.module.control_plane.aws_instance.control_plane["1"]`, `module.<name>.module.static_nodes["<group>"].aws_instance.node["1"]`, `module.<name>.module.control_plane.proxmox_virtual_environment_vm.control_plane["1"]`.
2. Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
3. Delete the Kubernetes node: `kubectl delete node <node>`.
4. Run `tofu apply -replace='<address>'`.
5. Read the plan. Verify that it replaces only the node you named.
6. Confirm the apply.
7. Verify that the node is `Ready` and, for a control-plane node, that every etcd pod is `Running`.

On Proxmox, also replace the firewall of an additional control-plane VM. See "Rolling to a new template" in the `proxmox-control-plane` README.

## `set_hostname` (for shared, byte-identical cloud-init payloads)

Every caller gets `set_hostname = true` (the default): `hostname`/`fqdn` are written into
cloud-config from `node_name`, required because RKE2/kubelet registers the node by OS
hostname. `set_hostname = false` omits both keys entirely. Do this only when VMs share one
rendered `cloud_init_user_data` and cannot each get their own render. An example is every
instance of an AWS Auto Scaling group, via one launch template. The platform's per-instance
metadata then supplies a unique hostname.

## DNS search domains

Kubelet copies the search domains of the node's `/etc/resolv.conf` into every pod. Pods use `ndots:5`, so a name such as `github.com` tries each search suffix first. If a search domain has a wildcard record, the name resolves to that wildcard and not to the real host.

If you set `dns_servers`, the module writes a kubelet `resolv.conf` with those servers and no `search` line. Every pod on the node then skips the search domains. If you do not set it, kubelet uses the node's own `/etc/resolv.conf`.

## Provider steps

`provider_steps` and `provider_files` carry what only one provider needs. This module
holds no AWS or Proxmox logic. `aws-boot-steps` builds the AWS steps: SSM Agent and,
with `aws_provider_id`, the providerID and the instance-type label. cluster-autoscaler
and the AWS cloud controller manager find a node's instance through the providerID.
`proxmox-boot-steps` builds the Proxmox steps: the iSCSI initiator name, and DNS
self-registration with `nsupdate` on the first server. A step is a name and cloud-init
`runcmd` commands. A provider file is a `write_files` entry that the commands read.
The provider steps run first. A failed `runcmd` command does not stop the later ones.

## Resources reserved for the node

Every node reserves CPU and memory for kubelet, containerd, RKE2 and the OS, so pods can
never take all of it. Without a reservation a crowded node doesn't evict pods: it reclaims
memory until containerd stops answering kubelet and the node goes NotReady. The node sizes
the reservation from its own memory and cores and writes it as an RKE2 `config.yaml.d`
drop-in before RKE2 starts. Memory follows EKS's per-pod formula, capped by GKE's older
tiers as GKE and AKS now do. Kubelet and containerd grow with the number of pods rather
than with the node's memory:

| | Reserved |
|---|---|
| `kube-reserved` memory | 11 MiB per pod plus 255 MiB at RKE2's default of 110 pods (1465 MiB), or 25% of the first 4 GiB, 20% of the next 4, 10% of the next 8, 6% up to 128 GiB and 2% above, whichever is smaller |
| `kube-reserved` CPU | 6% of the first core, 1% of the second, 0.5% of the next two, 0.25% above |
| `system-reserved` | 100m CPU, 256 MiB |
| `eviction-hard` | `memory.available<100Mi`, plus kubelet's own disk and inode defaults, which the flag would otherwise drop |

An 8 GiB node, for example, keeps about 5.8 GiB for pods and a 16 GiB node about 13.7 GiB.

The control plane runs as static pods, so server nodes give them requests through
`control-plane-resource-requests` (kube-apiserver 1024Mi, etcd 512Mi,
kube-controller-manager 256Mi, kube-scheduler 128Mi). The scheduler then counts their
memory, so the reservation does not have to cover it.

## Graceful shutdown

`graceful_shutdown` gives kubelet a window to evict pods when the OS is shutting down. A
node that is stopped or terminated then stops its workloads instead of having them killed
with it. Three files carry it, all written before RKE2 starts:

| File | Why |
|---|---|
| `/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf` | `shutdownGracePeriod` and `shutdownGracePeriodCriticalPods` |
| `/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml` | `kubelet-arg` cannot set either — they have no command-line flag — so kubelet is given `config-dir` and reads the drop-in above |
| `/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf` | `InhibitDelayMaxSec`, five seconds by default, is the longest logind lets kubelet hold the shutdown. Left alone it silently caps the grace period to five seconds |

`runcmd` restarts `systemd-logind` so the last of those applies to the node's first
shutdown, not just later ones. The total must stay under whatever the platform allows an
instance before it cuts the power, about two minutes on AWS. It must also leave room for
the longest `terminationGracePeriodSeconds` among the pods that land here. Null disables
all of it.

## OS updates

`os_auto_updates` installs `dnf-automatic` and `yum-utils` once the node has joined,
and enables `dnf-automatic-install.timer`, which installs updates daily and never
reboots. The timer runs at 06:00 and also 15 minutes after every boot. So a node that is powered off at 06:00, such as one on a power schedule, still updates. `rke2-server`, `rke2-agent` and `rke2-common` are excluded in `dnf.conf`, so
RKE2 only moves through system-upgrade-controller; `rke2-selinux` still updates.
`needs-restarting -r` from `yum-utils` is what kube-platform's os-updates collector
reads to report that a node needs a reboot. False leaves the node's packages as baked.

## Interface notes

- The CNI is always Cilium. On a genesis node, the boot program applies the Cilium
  manifest from the platform ref. `config.yaml` sets `disable: [rke2-cilium]` so RKE2's
  own Cilium chart never runs.
- `cluster_token`, `cluster_agent_token`, `agent_token_fetch_command` and
  `trusted_ca_pem` are `sensitive = true`. They reach the node only in the base64
  `write_files` of the payload, such as the 0600 `/etc/rancher/rke2/config.yaml`.
  `server-join` receives `cluster_token` the same way `server-init` does. Only `worker`
  runs `agent_token_fetch_command`, to read the agent token from the provider's secret
  store.
- `aws-node-pool` sets `set_hostname = false`, because every member of a pool shares one
  rendered payload.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_agent_token_fetch_command"></a> [agent\_token\_fetch\_command](#input\_agent\_token\_fetch\_command) | Shell command that prints the rke2 agent join token to stdout on the node, for example a cloud CLI call that reads a secrets store. Required for node\_role worker; ignored otherwise. Sensitive: it is written to the 0600 /opt/kube-compute/secrets.env. | `string` | `null` | no |
| <a name="input_cert_mode"></a> [cert\_mode](#input\_cert\_mode) | Certificate issuer mode deployed by kube-platform. 'selfsigned' needs no dependencies. 'byo' expects a Secret named byo-ca-tls in the cert-manager namespace. 'acme' requires DNS-01 config (separate setup). | `string` | `"selfsigned"` | no |
| <a name="input_cluster_agent_token"></a> [cluster\_agent\_token](#input\_cluster\_agent\_token) | Separate secret accepted only from agents (config.yaml agent-token), so a worker can join as an agent but never as a server. Used only for server-init. Sensitive: written to the 0600 /etc/rancher/rke2/config.yaml. | `string` | `null` | no |
| <a name="input_cluster_fqdn"></a> [cluster\_fqdn](#input\_cluster\_fqdn) | Optional DNS name for the API/kubeconfig server and an extra TLS SAN. Null = use the node IP only. | `string` | `null` | no |
| <a name="input_cluster_fqdn_suffix"></a> [cluster\_fqdn\_suffix](#input\_cluster\_fqdn\_suffix) | Optional DNS suffix for the platform web UI hostnames (e.g. 'my-cluster.example.com' gives argocd.my-cluster.example.com). It differs from cluster\_fqdn and must not start with 'api.'. Null or empty disables platform ingress. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster name. It sets the clusterName Helm parameter, the iSCSI initiator name and CLUSTER\_NAME in node.env. | `string` | n/a | yes |
| <a name="input_cluster_token"></a> [cluster\_token](#input\_cluster\_token) | Shared secret that joins a server to the cluster (config.yaml token). Required for server-init and server-join. Sensitive: written to the 0600 /etc/rancher/rke2/config.yaml. | `string` | `null` | no |
| <a name="input_control_plane_taint"></a> [control\_plane\_taint](#input\_control\_plane\_taint) | When true, the rke2 server install adds a node-taint: CriticalAddonsOnly=true:NoExecute so user workloads are excluded from this control-plane node. Only meaningful for node\_role = server-init or server-join. | `bool` | `false` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Resolver IPs for kubelet and pods, for example the list your VM network config uses. Null or empty (the default) leaves kubelet on the node's own /etc/resolv.conf. A list writes a kubelet resolv.conf with no search domain. See the README, section "DNS search domains". | `list(string)` | `null` | no |
| <a name="input_extra_server_manifests"></a> [extra\_server\_manifests](#input\_extra\_server\_manifests) | Arbitrary RKE2 auto-deploy manifest files (filename => full YAML content) written to /var/lib/rancher/rke2/server/manifests/ on server-init/server-join nodes only. This module does not interpret the content. | `map(string)` | `{}` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional tags forwarded to the platform bootstrap Application (as part of helm.valuesObject.extraTags) so Kubernetes-managed resources can tag themselves consistently with the node's own tags. | `map(string)` | `{}` | no |
| <a name="input_extra_tls_sans"></a> [extra\_tls\_sans](#input\_extra\_tls\_sans) | Additional tls-san: entries for the rke2 server cert. Only meaningful for node\_role = server-init or server-join. | `list(string)` | `[]` | no |
| <a name="input_gitops_platform_enabled"></a> [gitops\_platform\_enabled](#input\_gitops\_platform\_enabled) | Whether to bootstrap kube-platform at all. false = skip Argo CD and the platform Application entirely (a bare RKE2+Cilium cluster) regardless of gitops\_platform\_repo\_url/\_revision. Only meaningful for node\_role = server-init. | `bool` | `true` | no |
| <a name="input_gitops_platform_repo_url"></a> [gitops\_platform\_repo\_url](#input\_gitops\_platform\_repo\_url) | Source repo of the Argo CD platform Application (kube-platform or a fork). Null or empty (the default) uses local.pinned\_platform\_repo\_url. The genesis node also clones it for its Cilium and Argo CD manifests. Only for server-init. | `string` | `null` | no |
| <a name="input_gitops_platform_revision"></a> [gitops\_platform\_revision](#input\_gitops\_platform\_revision) | Branch, tag or SHA the platform Application tracks. The genesis node clones the same ref for its boot manifests (40 hex digits means a commit). Null or empty (the default) uses local.pinned\_platform\_revision, the protected main branch of kube-platform. | `string` | `null` | no |
| <a name="input_gitops_workloads_path"></a> [gitops\_workloads\_path](#input\_gitops\_workloads\_path) | Path within the workloads repo Argo CD applies. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"."` | no |
| <a name="input_gitops_workloads_repo_url"></a> [gitops\_workloads\_repo\_url](#input\_gitops\_workloads\_repo\_url) | Optional source repo of a workloads Application, independent of the platform Application and with no ordering between them. Null or empty (the default) creates none. Only for node\_role = server-init. | `string` | `null` | no |
| <a name="input_gitops_workloads_revision"></a> [gitops\_workloads\_revision](#input\_gitops\_workloads\_revision) | Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"main"` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet delays an OS shutdown to evict pods. critical\_seconds is the part reserved for critical pods and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables it. Keep the total well under 2 minutes. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_node_fqdn_label"></a> [node\_fqdn\_label](#input\_node\_fqdn\_label) | Optional override for the leftmost fqdn label (before cluster\_fqdn\_suffix). Null (the default) uses node\_name. The fqdn suffix already carries the cluster name, so a cluster-name prefix here is redundant. | `string` | `null` | no |
| <a name="input_node_labels"></a> [node\_labels](#input\_node\_labels) | Extra node-label: entries applied at rke2 install time, e.g. { "topology.kubernetes.io/zone" = "eu-west-1a" }. Only meaningful for node\_role = worker. | `map(string)` | `{}` | no |
| <a name="input_node_name"></a> [node\_name](#input\_node\_name) | Unique per-node name, set as this node's cloud-init hostname (and fqdn, when cluster\_fqdn\_suffix is set). RKE2/kubelet defaults the registered Kubernetes node name to the OS hostname, so every node in a multi-node cluster MUST get a distinct value here. | `string` | n/a | yes |
| <a name="input_node_role"></a> [node\_role](#input\_node\_role) | Bootstrap role this node is being installed for: 'server-init' (first control-plane node — forms the etcd cluster), 'server-join' (an additional control-plane node), or 'worker' (joins as an agent only, no control plane). | `string` | n/a | yes |
| <a name="input_node_taints"></a> [node\_taints](#input\_node\_taints) | Extra node-taint entries applied at RKE2 install time, each a full 'key=value:Effect' string (e.g. ['dedicated=true:NoSchedule']). Only for node\_role = worker; server roles use control\_plane\_taint. Only a taint keeps other pods off a node. | `list(string)` | `[]` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Install OS updates daily with dnf-automatic, without rebooting, once the node has joined. RKE2 packages are excluded, because system-upgrade-controller upgrades them. Also installs yum-utils, whose needs-restarting reports a due reboot. False leaves packages as baked. | `bool` | `true` | no |
| <a name="input_platform_extra_helm_parameters"></a> [platform\_extra\_helm\_parameters](#input\_platform\_extra\_helm\_parameters) | Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. | `map(string)` | `{}` | no |
| <a name="input_platform_helm_values_object"></a> [platform\_helm\_values\_object](#input\_platform\_helm\_values\_object) | Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings. | `any` | `null` | no |
| <a name="input_provider_files"></a> [provider\_files](#input\_provider\_files) | Files that the provider steps need, written by cloud-init before any command runs. Sensitive content is allowed. | <pre>list(object({<br/>    path        = string<br/>    content     = string<br/>    permissions = optional(string, "0644")<br/>  }))</pre> | `[]` | no |
| <a name="input_provider_steps"></a> [provider\_steps](#input\_provider\_steps) | Boot steps owned by one provider. The provider module builds them, so this module holds no provider logic. Each has a name and cloud-init runcmd commands (a command is a list of strings). They run in order before the module's own commands. | <pre>list(object({<br/>    name     = string<br/>    commands = list(list(string))<br/>  }))</pre> | `[]` | no |
| <a name="input_registration_address"></a> [registration\_address](#input\_registration\_address) | IP or FQDN of the existing cluster's registration endpoint (a control plane's registration\_address output). Required for server-join and worker. Optional for server-init: if set, the node probes it at boot and joins the cluster that answers (rejoin probe). | `string` | `null` | no |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream registries directly. | `string` | `null` | no |
| <a name="input_rejoin_probe_addresses"></a> [rejoin\_probe\_addresses](#input\_rejoin\_probe\_addresses) | IPs or FQDNs a server-init node probes in order before it starts etcd. It joins the first cluster that answers and initializes a new one only if none does. Use it when registration\_address points at the node itself. Empty (the default) probes registration\_address. | `list(string)` | `[]` | no |
| <a name="input_set_hostname"></a> [set\_hostname](#input\_set\_hostname) | Whether cloud-init sets hostname and fqdn from node\_name. true (the default) is required for a node with its own render, because RKE2 registers by OS hostname. false omits both keys, for a render shared by several VMs such as an Auto Scaling group. | `bool` | `true` | no |
| <a name="input_trusted_ca_in_image"></a> [trusted\_ca\_in\_image](#input\_trusted\_ca\_in\_image) | Whether the node image already carries trusted\_ca\_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. If true, user data omits the PEM, but the value is still used for the containerd TLS pin. The boot program fails if the file is missing. | `bool` | `false` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) to add to the OS trust store via update-ca-trust, and to pin containerd's TLS verification of a registry\_mirror\_url host. Effect, not use case: a private CA, or null to skip. Sensitive: written directly into the cloud-init payload as the anchors file, base64-encoded. | `string` | `null` | no |
| <a name="input_workloads_extra_helm_parameters"></a> [workloads\_extra\_helm\_parameters](#input\_workloads\_extra\_helm\_parameters) | Additional Helm parameters forwarded verbatim to the workloads Application. Only meaningful when gitops\_workloads\_repo\_url is set. | `map(string)` | `{}` | no |
| <a name="input_workloads_helm_values_object"></a> [workloads\_helm\_values\_object](#input\_workloads\_helm\_values\_object) | Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations. | `any` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_boot_steps"></a> [boot\_steps](#output\_boot\_steps) | Every step of this node's boot, in the order it runs: the provider steps, the module's cloud-init commands, the steps of the boot program, then the commands that follow it. The names say what the node does, so a test can assert the exact list. |
| <a name="output_cloud_init_user_data"></a> [cloud\_init\_user\_data](#output\_cloud\_init\_user\_data) | Complete '#cloud-config' document for this node: hostname, base64 write\_files payloads (RKE2 config, registries, CA, manifests) and a runcmd that runs the bootstrap script. Deliver it verbatim as user data. Sensitive: it carries the join tokens and the CA. |
| <a name="output_node_name"></a> [node\_name](#output\_node\_name) | Node name this payload was rendered for — the OS hostname it sets, and therefore the Kubernetes node name RKE2/kubelet will register. Echoed back so a caller can key snippet filenames off the same value without recomputing it. |
<!-- END_TF_DOCS -->
