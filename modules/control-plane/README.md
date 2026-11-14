# aws-control-plane

Provisions the AWS control plane for an RKE2 cluster: its control-plane node(s) plus the
cluster-wide resources. It consumes `node-bootstrap` for per-cluster identity, join
tokens, and GitOps bootstrap. A control plane with `control_plane_count = 1` is a complete
single-node cluster.

## Boot flow: pre-baked AMI + lean cloud-init, no live connection

This module runs **no live Ansible** at `apply` time. It renders `node-bootstrap`'s
`#cloud-config` payload (node identity, join tokens, registries/CA, GitOps Application
manifests — see `modules/node-bootstrap/README.md`) and attaches it as
`user_data_base64`. Nothing in this module connects to the node, waits on it, or observes
it converge. `apply` returns as soon as the instance and its user-data exist.

The heavy half of RKE2 bootstrap (binaries, SELinux policy, kernel modules) is expected to
already be baked into the AMI, via `kube-images`' `kube-node/packer/aws/`
template. You must pass a kube-images-baked AMI with `os_image_ami_id`, or its name with
`os_image_name`. If you pass neither, the plan fails. A stock image has no RKE2, so a node
booted from it would never join. With `os_image_name`, the module resolves the ID itself
via a data lookup scoped to your own account and the derived architecture. A pattern with
the build date omitted (using EC2's `*`/`?` wildcards) resolves to the most recent
matching build. This mirrors `proxmox-control-plane`'s `proxmox_template_vm_id`.

### Keeping user data under EC2's limit

EC2 rejects `RunInstances` when decoded user data exceeds 16384 bytes. Static content therefore stays out of the payload. The genesis node reads the Cilium and Argo CD manifests from a clone of the platform ref. With `trusted_ca_in_image`, a CA is baked into the image. The bootstrap program travels in the payload
with its comments removed. A precondition on the instance names the levers when the
limit is exceeded.

### A change to the user data of a running node

A change to any input in the user data, such as a Helm parameter of the platform
Application, does not touch a running node. The instance ignores the change and keeps
the user data it booted with. cloud-init reads user data only at the first boot, so
the node would not apply the change anyway.

To apply a change, replace the node on purpose. The replaced node boots with the
current user data.

The addresses are:

- First node: `module.<name>.aws_instance.control_plane["0"]`
- Other nodes: `module.<name>.aws_instance.control_plane["1"]`

Inside `aws-cluster`, put `module.<name>.module.control_plane.` before the resource
type instead.

> **Warning:** Replacing a single-node cluster loses the cluster.

1. If the cluster has one node, stop. Replacing it loses the cluster.
2. Select a node. Replace the additional nodes first, one at a time. Start with key `"1"`.
3. Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
4. Delete the Kubernetes node: `kubectl delete node <node>`.
5. Replace the instance: `tofu apply -replace='<address>'`.
6. Verify that the node is `Ready`: `kubectl get nodes`.
7. Verify that every etcd pod is `Running`: `kubectl -n kube-system get pods -l component=etcd`.
8. If another additional node needs the change, go back to step 2.

> **Warning:** Replace the first node last, in its own apply.

9. Do steps 3 to 7 for the first node.

Do not replace several nodes in one apply: etcd loses its quorum.

## Scope

The module provisions the **node and only what is intrinsic to it**. That is the EC2
instance, its own security group, its IAM role/instance-profile, and (optionally) a DNS
record. It **never creates network fabric** (VPC, subnet, internet gateway, NAT, route
tables). You plug in existing networking, or it falls back to the account's default VPC.

## Topology

- **`control_plane_count`** — `1` (default), `3`, or `5`. `2` and `4` are rejected (no
  fault-tolerance benefit, split-brain risk). `3`/`5` place one control-plane node per
  availability zone behind an internal NLB on 6443. They require `control_plane_subnets`,
  a map of AZ -> subnet id spanning at least 3 distinct AZs. Fewer than 3 AZs fails the
  plan with a clear error. `registration_address` becomes the NLB's DNS name. The first
  control-plane node probes that address at boot. If it is reachable, the node joins the
  existing quorum. If not, it initializes. RKE2 has no `--cluster-init` flag. The first
  server is simply the one whose config omits a `server:` join address. So replacing it is
  always a safe rejoin, never a second initialization.
- **`cluster_type`** — `all_in_one` (default; control-plane node stays schedulable) or
  `dedicated_control_plane` (tainted `CriticalAddonsOnly=true:NoExecute`; for use once
  node pools exist). Derived from this explicit intent, never from node counts — node
  pools are separate Terraform state this module cannot see.
- **Datastore** — always embedded etcd (RKE2's only supported datastore), including for
  `control_plane_count = 1`, for one consistent datastore and uniform snapshots.


## Networking

Three ways to specify the subnet (pick one):

- **`subnet_id`** — pass the literal subnet ID to launch into your own subnet.
- **`subnet_name`** — pass the Name tag; the module resolves the ID via a data lookup. Pair with
  `vpc_name` to scope the search when the tag is not globally unique.
- **Neither** — the module falls back to a subnet in the account's **default VPC** (data lookup;
  it never *creates* a VPC). Accounts whose default VPC was deleted must pass a subnet.

## DNS (optional)

DNS is a convenience, not a hard dependency:

- Set `cluster_domain` to get a named FQDN (`api.<cluster>.<domain>`) and a wildcard
  (`*.<cluster>.<domain>`). Omit it and the node is reachable by IP only.
- Additionally set `hosted_zone_id` to have the module create the wildcard A record in
  that Route53 zone.
- If you don't pass `hosted_zone_id`, the module creates **no** DNS record. Register the
  `wildcard_dns_name` output at the `cluster_ip` in whatever DNS you run (Route53, a local
  resolver, RFC2136, external-dns, or an `sslip.io`-style fallback).

## Access

Zero inbound beyond `ingress_ports` (default 80/443/6443) from `allowed_ingress_cidrs`; no SSH.
IMDSv2 is enforced. Operator access to the node is via AWS SSM (the IAM role attaches
`AmazonSSMManagedInstanceCore`) — there is no inbound shell port.

## Join flow (workers and, later, additional control-plane nodes)

This module generates its own join tokens directly (`random_password.server_token` /
`random_password.agent_token`), matching `proxmox-control-plane`'s precedent. Two tokens
are never exposed as raw values outside the module. `cluster_token` is the **server
token**, used by both genesis and every `server-join` node. `cluster_agent_token` is the
**agent token**, mirrored into an SSM `SecureString` that workers fetch via their own
instance IAM role. Workers receive only the agent token, so a compromised worker cannot
rejoin as control-plane/etcd.

One security group carries east-west traffic: `aws_security_group.cluster` (self-referencing,
every member, exposed as `cluster_security_group_id` for an `aws-node-pool` unit to attach
to by id). It admits all traffic among members, workers included, so etcd (2379-2380) is not
limited to control-plane nodes. `registration_address` is what a joining node's
`--server` flag targets — for `control_plane_count = 1` this is the control-plane node's private
IP.

## HA control plane (`control_plane_count` > 1)

`control_plane_subnets` (a map of AZ -> subnet id) is required once `control_plane_count > 1` —
the module does not auto-discover multi-AZ subnets. Its keys ARE the AZs, so a caller cannot
accidentally supply two subnets in the same AZ. Pass at least 3 entries spanning at least 3
distinct AZs; fewer fails plan explicitly rather than silently forming a weaker quorum.

Once `control_plane_count > 1`, the single `subnet_id`/`subnet_name` above is unused for
control-plane placement. The module's own VPC (for its security groups and the NLB target
group) is derived from `control_plane_subnets` itself. So it can never disagree with where
the instances actually launch.

The genesis node is unchanged in shape from `control_plane_count = 1`. Additional
control-plane nodes (`server-join`) bootstrap concurrently with it and join via the NLB.
They retry the registration endpoint the same way a worker retries its join target.
node-bootstrap's own staggered, self-healing retry handles the one genuine etcd constraint
(one non-voting learner at a time) among the joining siblings. Argo/platform GitOps inputs
are only ever passed to the genesis node, so platform bootstrap manifests never race on
more than one server.

## Cilium and Argo CD manifests

The genesis node clones the platform ref (`gitops_platform_repo_url` at `gitops_platform_revision`) before RKE2 starts. It takes `bootstrap/rendered/cilium.yaml` and `bootstrap/rendered/argocd.yaml` from the clone. The AMI holds neither. The AMI must hold git. See [`node-bootstrap`](../node-bootstrap/README.md).

## Container Network Interface (CNI)

The CNI is always Cilium. The Canal variant does not work on AlmaLinux 10, this project's only supported OS: its kernel dropped the legacy `br_netfilter`, `xt_conntrack` and `xt_comment` modules. The Cilium manifest from the platform ref sets the operator to `1` replica (chart default `2`) on every topology. So a single-node cluster has no `Pending` replica. The cluster security group's
self-referencing all-protocol rule already covers the CNI traffic.

## Registration endpoint modes (`endpoint_mode`)

Only relevant once `control_plane_count > 1` — a single control-plane node has no registration
endpoint at all.

- **`loadbalancer`** (default) — an internal NLB across all control-plane nodes on
  6443.
- **`dns`** — one Route53 A record per control-plane node under a shared name
  (`cp.<cluster_name>.<cluster_domain>`), with multivalue-answer routing. Each record is
  backed by a `CLOUDWATCH_METRIC` health check on that instance's own EC2 status-check
  alarm. Route53's public health checkers can't reach a private VPC IP directly, so the
  alarm is the bridge. Requires `cluster_domain` and a resolvable hosted zone. Cheaper
  than an NLB; failover is TTL-bound (`ttl = 10`), not instant.
- **`static`** — creates no load balancer or DNS record; `static_registration_address`
  is used verbatim. For a consumer that already runs its own front end.

## Input notes

See the generated tables below. Environment-specific values are inputs — none are baked in. Compute sizing
is AWS-native: `instance_type` (bundles vCPU+memory), `root_volume_size_gb`, `root_volume_type`.
`os_image_ami_id` or `os_image_name` is required (see "Boot flow"). Join tokens and the cluster security group are **not** inputs — this
module generates and owns them directly (see "Join flow").

## Outputs for workers

`registration_address` is a node's private IP for `control_plane_count = 1`. Otherwise `endpoint_mode`
shapes it. `control_plane_node_refs` lists every control-plane node, not just the first.
An `aws-node-pool` unit reads `cluster_security_group_id` and `agent_token_ssm_parameter` through a
`dependency "control_plane"` block. It attaches workers to the cluster security group and fetches the
agent token. Raw join token values are never outputs. Workers only need the SSM parameter name.

## Out of scope (lives in the consumer repo)

Team-specific operational policy is **not** in this module — e.g. a schedule that stops and
starts the nodes. `aws-cluster` has one, `power_schedule`. Used on its own, this module needs an
`aws_scheduler_schedule` in your own config referencing the `instance_id` output.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | CIDR blocks allowed inbound to the cluster ports — the networks you administer/reach the cluster from. Required — environment-specific. | `list(string)` | n/a | yes |
| <a name="input_aws_provider_id"></a> [aws\_provider\_id](#input\_aws\_provider\_id) | Registers every control-plane node with providerID aws:///<zone>/<instance-id>. Needed on every node of a cluster whose nodes cluster-autoscaler and the AWS cloud controller manager look up by instance. Changing it replaces the nodes. | `bool` | `false` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region the node runs in. Exposed as an output so the SSM control-plane scripts know which region to target. Does NOT configure the provider — the caller sets the provider region; pass the same value here. | `string` | n/a | yes |
| <a name="input_cert_mode"></a> [cert\_mode](#input\_cert\_mode) | Certificate issuer mode deployed by kube-platform. Passed through to the node-bootstrap platform Application parameters. 'selfsigned' (default), 'byo' (consumer provides byo-ca-tls Secret), 'acme' (ACME DNS-01). | `string` | `"selfsigned"` | no |
| <a name="input_cluster_domain"></a> [cluster\_domain](#input\_cluster\_domain) | Optional DNS suffix for the cluster, e.g. 'example.internal'. When set, the FQDN is <cluster\_name>.<cluster\_domain> and the wildcard is *.<cluster\_name>.<cluster\_domain>. Null = node is reachable by IP only. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter or digit. | `string` | n/a | yes |
| <a name="input_cluster_type"></a> [cluster\_type](#input\_cluster\_type) | Cluster topology: 'all\_in\_one' (control-plane nodes stay schedulable) or 'dedicated\_control\_plane' (control-plane nodes are tainted, so workloads run only on node pools). The module cannot derive this from the worker count, because node pools are separate state. | `string` | `"all_in_one"` | no |
| <a name="input_control_plane_count"></a> [control\_plane\_count](#input\_control\_plane\_count) | Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain. 3 or 5 places one control-plane node per availability zone behind an internal NLB (see control\_plane\_subnets). | `number` | `1` | no |
| <a name="input_control_plane_subnets"></a> [control\_plane\_subnets](#input\_control\_plane\_subnets) | Map of availability zone to subnet id for control-plane placement. Required when control\_plane\_count > 1: one node per AZ, in at least 3 AZs. Ignored for one node; use subnet\_id or subnet\_name. Each subnet must already exist in the AZ of its key. | `map(string)` | `null` | no |
| <a name="input_destroy_after"></a> [destroy\_after](#input\_destroy\_after) | Something that must outlive this module's nodes at destroy. It orders their destruction and nothing else, so it is never read as a value. | `string` | `null` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Upstream DNS resolver IPs. They give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record. Null keeps the kubelet default. 169.254.169.253 is the Amazon-provided resolver. | `list(string)` | `null` | no |
| <a name="input_endpoint_mode"></a> [endpoint\_mode](#input\_endpoint\_mode) | How joining nodes reach the registration endpoint when control\_plane\_count > 1: 'loadbalancer' (default) creates an internal NLB; 'dns' creates Route53 multivalue records with health checks and needs cluster\_domain and a hosted zone; 'static' uses static\_registration\_address as given. | `string` | `"loadbalancer"` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional tags applied to every AWS resource this module creates (EC2 instance, root EBS volume, security group, IAM role), and forwarded to node-bootstrap so platform-managed resources (e.g. CSI-provisioned storage) can tag themselves consistently. | `map(string)` | `{}` | no |
| <a name="input_gitops_platform_enabled"></a> [gitops\_platform\_enabled](#input\_gitops\_platform\_enabled) | Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application. Sourced from this cluster's cluster-facts unit. | `bool` | `true` | no |
| <a name="input_gitops_platform_repo_url_override"></a> [gitops\_platform\_repo\_url\_override](#input\_gitops\_platform\_repo\_url\_override) | Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin. Sourced from this cluster's cluster-facts unit. | `string` | `null` | no |
| <a name="input_gitops_platform_revision_override"></a> [gitops\_platform\_revision\_override](#input\_gitops\_platform\_revision\_override) | Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default. Sourced from this cluster's cluster-facts unit. | `string` | `null` | no |
| <a name="input_gitops_workloads_path"></a> [gitops\_workloads\_path](#input\_gitops\_workloads\_path) | Path within the workloads repo Argo CD applies. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"."` | no |
| <a name="input_gitops_workloads_repo_url"></a> [gitops\_workloads\_repo\_url](#input\_gitops\_workloads\_repo\_url) | Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application. Sourced from this cluster's cluster-facts unit. | `string` | `null` | no |
| <a name="input_gitops_workloads_revision"></a> [gitops\_workloads\_revision](#input\_gitops\_workloads\_revision) | Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"main"` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_hosted_zone_id"></a> [hosted\_zone\_id](#input\_hosted\_zone\_id) | Route53 hosted zone ID. Alternative to hosted\_zone\_name — pass the literal ID. Requires cluster\_domain to be set. Null = create no record; register DNS yourself using the wildcard\_dns\_name output. | `string` | `null` | no |
| <a name="input_hosted_zone_name"></a> [hosted\_zone\_name](#input\_hosted\_zone\_name) | Name of the Route53 private hosted zone (e.g. "example.internal"). Alternative to hosted\_zone\_id — the module resolves the ID via a data lookup. Requires cluster\_domain to be set. | `string` | `null` | no |
| <a name="input_ingress_ports"></a> [ingress\_ports](#input\_ingress\_ports) | TCP ports opened on the module SG: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH). | `list(number)` | <pre>[<br/>  80,<br/>  443,<br/>  6443<br/>]</pre> | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type (bundles vCPU + memory). CPU arch (arm64/x86\_64) is derived from the family prefix for AMI selection. | `string` | `"m7g.medium"` | no |
| <a name="input_manage_wildcard_dns_record"></a> [manage\_wildcard\_dns\_record](#input\_manage\_wildcard\_dns\_record) | Whether this module owns the *.<cluster>.<domain> A record. aws-cluster sets it false when ingress runs on a platform node group and points the record there itself. The api.<cluster>.<domain> record is always created. | `bool` | `true` | no |
| <a name="input_node_name_template"></a> [node\_name\_template](#input\_node\_name\_template) | Name for each control-plane node: its hostname, Kubernetes node name and Name tag. {zone} becomes the last letter of the node's availability zone, and {number} the node's number as two digits (01, 02, ...). Null keeps cp-<cluster\_name>-<n>. | `string` | `null` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Installs OS updates daily with dnf-automatic, without rebooting. See node-bootstrap's own variable. | `bool` | `true` | no |
| <a name="input_os_image_ami_id"></a> [os\_image\_ami\_id](#input\_os\_image\_ami\_id) | AMI ID for the node. Tested with AlmaLinux 10 (RHEL-family — node-bootstrap uses dnf and<br/>update-ca-trust). Other RHEL-family images (Rocky, AL2023) may work but are untested —<br/>no compatibility guarantee. Null = latest AlmaLinux 10 for the derived architecture via<br/>data lookup. | `string` | `null` | no |
| <a name="input_os_image_name"></a> [os\_image\_name](#input\_os\_image\_name) | AMI name of a kube-images build for the node. Alternative to os\_image\_ami\_id, which wins if set. Accepts EC2 Name wildcards (*, ?); a pattern without the build date picks the newest match. | `string` | `null` | no |
| <a name="input_platform_extra_helm_parameters"></a> [platform\_extra\_helm\_parameters](#input\_platform\_extra\_helm\_parameters) | Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. See node-bootstrap for full description. | `map(string)` | `{}` | no |
| <a name="input_platform_helm_values_object"></a> [platform\_helm\_values\_object](#input\_platform\_helm\_values\_object) | Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings. | `any` | `null` | no |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream. | `string` | `null` | no |
| <a name="input_root_volume_size_gb"></a> [root\_volume\_size\_gb](#input\_root\_volume\_size\_gb) | Root EBS volume size (GB). Covers OS + container image cache. | `number` | `20` | no |
| <a name="input_root_volume_type"></a> [root\_volume\_type](#input\_root\_volume\_type) | Root EBS volume type (gp3, gp2, io2, ...). | `string` | `"gp3"` | no |
| <a name="input_static_registration_address"></a> [static\_registration\_address](#input\_static\_registration\_address) | Consumer-supplied registration endpoint address (e.g. your own load balancer's DNS name), used verbatim as registration\_address when endpoint\_mode = "static". Ignored otherwise. The module creates no load balancer or DNS record for this mode — you own that infrastructure. | `string` | `null` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet to launch the node into. Pass it to plug in your own networking. Null = the module<br/>falls back to a subnet in the account's DEFAULT VPC (a data lookup; the module never CREATES a<br/>VPC/subnet). Accounts whose default VPC was deleted must pass a subnet\_id or subnet\_name. | `string` | `null` | no |
| <a name="input_subnet_min_free_ips"></a> [subnet\_min\_free\_ips](#input\_subnet\_min\_free\_ips) | Free IP addresses a subnet\_names candidate needs before a new cluster is placed in it: one for each node launched with the cluster, not only the control plane. aws-cluster passes the control plane plus its static nodes. Nodes added later, by the autoscaler, are not counted. | `number` | `1` | no |
| <a name="input_subnet_name"></a> [subnet\_name](#input\_subnet\_name) | Name tag of the subnet to launch the node into. Alternative to subnet\_id — the module resolves the ID via a data lookup. Pair with vpc\_name when the name tag is not globally unique. | `string` | `null` | no |
| <a name="input_subnet_names"></a> [subnet\_names](#input\_subnet\_names) | Candidate subnets by Name tag, in order of preference. The first with subnet\_min\_free\_ips free addresses wins, and the choice stays in state. To choose again, replace terraform\_data.subnet\_choice[0]; a new choice replaces every node. List form of subnet\_name. | `list(string)` | `null` | no |
| <a name="input_trusted_ca_in_image"></a> [trusted\_ca\_in\_image](#input\_trusted\_ca\_in\_image) | Whether the node image already carries trusted\_ca\_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. Passed through to node-bootstrap, which then keeps the PEM out of user data. | `bool` | `false` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive. | `string` | `null` | no |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | Name tag of the VPC. Pair with subnet\_name to scope the subnet lookup to a specific VPC. Ignored when subnet\_id is used. | `string` | `null` | no |
| <a name="input_workloads_extra_helm_parameters"></a> [workloads\_extra\_helm\_parameters](#input\_workloads\_extra\_helm\_parameters) | Helm parameters forwarded verbatim to the workloads Application. See node-bootstrap for full description. | `map(string)` | `{}` | no |
| <a name="input_workloads_helm_values_object"></a> [workloads\_helm\_values\_object](#input\_workloads\_helm\_values\_object) | Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations. | `any` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_agent_token_ssm_parameter"></a> [agent\_token\_ssm\_parameter](#output\_agent\_token\_ssm\_parameter) | SSM Parameter Store name (SecureString) holding the agent join token. An aws-node-pool unit's workers fetch it at boot via their own instance IAM role — never embedded in user\_data. |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | Region the node runs in (the verb-scripts need it for SSM calls). |
| <a name="output_cluster_fqdn"></a> [cluster\_fqdn](#output\_cluster\_fqdn) | API server / kubeconfig FQDN, or null when no cluster\_domain was given (IP-only). |
| <a name="output_cluster_ip"></a> [cluster\_ip](#output\_cluster\_ip) | Private IP of the RKE2 node. Register your DNS wildcard at this address. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Cluster name passed to the module. Use this to name local kubeconfig files and other client-side resources. |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Self-referencing security group id shared by every cluster member. This module's own instances attach to it by id; an aws-node-pool unit depends on this module to attach its workers the same way. |
| <a name="output_connectivity_user_data_base64"></a> [connectivity\_user\_data\_base64](#output\_connectivity\_user\_data\_base64) | base64gzip of the genesis node's user data. Exposed for tests and debugging. |
| <a name="output_control_plane_node_refs"></a> [control\_plane\_node\_refs](#output\_control\_plane\_node\_refs) | Map of control-plane node name -> {instance\_id, provider}. The control-plane abstraction (SSM send-command today) targets every node from this map instead of a single node\_control\_ref. |
| <a name="output_effective_ami_id"></a> [effective\_ami\_id](#output\_effective\_ami\_id) | AMI ID used (os\_image\_ami\_id, or the os\_image\_name lookup). |
| <a name="output_hosted_zone_id"></a> [hosted\_zone\_id](#output\_hosted\_zone\_id) | Route53 zone the cluster's records live in, resolved from hosted\_zone\_id or hosted\_zone\_name. Null when no domain is configured. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | Provider-native node ID. |
| <a name="output_node_arch"></a> [node\_arch](#output\_node\_arch) | CPU architecture reported by AWS for the instance type (arm64 or x86\_64). |
| <a name="output_node_control_ref"></a> [node\_control\_ref](#output\_node\_control\_ref) | Handle the control-plane verb-scripts use to reach the node out-of-band (kubeconfig fetch, break-glass shell). For AWS: the instance ID, targeted via 'aws ssm send-command'/'aws ssm start-session' in region aws\_region. |
| <a name="output_node_iam_role_name"></a> [node\_iam\_role\_name](#output\_node\_iam\_role\_name) | IAM role name attached to the node. Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO). |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM). |
| <a name="output_node_security_group_id"></a> [node\_security\_group\_id](#output\_node\_security\_group\_id) | Security group carrying this cluster's external ingress\_ports rules. A worker that takes over the ingress controller needs it, or the ports stay open on a node no longer serving them. Distinct from cluster\_security\_group\_id, which is east-west only. |
| <a name="output_registration_address"></a> [registration\_address](#output\_registration\_address) | Address workers and joining servers use to reach the cluster API. With one control-plane node, its private IP. Otherwise it depends on endpoint\_mode: the NLB DNS name, the Route53 record name, or static\_registration\_address. |
| <a name="output_subnet_id"></a> [subnet\_id](#output\_subnet\_id) | Subnet ID the genesis node launched into; the first control-plane AZ slot when control\_plane\_count > 1, and identical to the single-node resolution below that. Consumed by aws-static-node so a worker inherits the control plane's availability zone. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID the control plane launched into (derived from the subnet — the single-node subnet\_id/subnet\_name/default-VPC fallback for control\_plane\_count = 1, or the control-plane subnets themselves for control\_plane\_count > 1). |
| <a name="output_wildcard_dns_name"></a> [wildcard\_dns\_name](#output\_wildcard\_dns\_name) | Wildcard hostname for cluster services (e.g. *.example.example.internal), or null when no cluster\_domain was given. Point this at cluster\_ip in your DNS of choice. |
<!-- END_TF_DOCS -->

## Testing

    cd modules/aws-control-plane
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS is run by the operator from a consumer repo.
