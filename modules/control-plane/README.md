# aws-control-plane

Provisions the AWS control plane for an RKE2 cluster — its control-plane node(s) plus the
cluster-wide resources — consuming `node-bootstrap` for per-cluster identity, join tokens, and
GitOps bootstrap. A control plane with `control_plane_count = 1` is a complete single-node
cluster.

## Boot flow: pre-baked AMI + lean cloud-init, no live connection

This module runs **no live Ansible** at `apply` time. It renders `node-bootstrap`'s
`#cloud-config` payload (node identity, join tokens, registries/CA, GitOps Application
manifests — see `modules/node-bootstrap/README.md`) and attaches it as `user_data_base64`,
combined via a cloud-init MIME multipart document with a small AWS-only shell-script part that
enables the SSM Agent (SSM stays this module's operator-access path, independent of bootstrap).
Nothing in this module connects to the node, waits on it, or observes it converge; `apply`
returns as soon as the instance and its user-data exist.

The heavy half of RKE2 bootstrap (binaries, SELinux policy, kernel modules, genesis Cilium/Argo
CD manifests) is expected to already be baked into the AMI, via `kube-image`'s `packer/aws/`
template. **`os_image_ami_id` is opt-in**: pass a kube-image-baked AMI id to get a fully working
cluster. `os_image_name` is an alternative to `os_image_ami_id` — pass the AMI's name (e.g.
kube-image's self-descriptive build name) instead of its ID, and the module resolves the ID
itself via a data lookup scoped to your own account and the derived architecture; a pattern
with the build date/suffix omitted (using EC2's `*`/`?` Name-filter wildcards) resolves to the
most recent matching build. The default fallback — latest stock AlmaLinux 10, when both are
left null — has **no RKE2 baked in**, so a node booted from it will not join a cluster; it
exists only so the AMI lookup resolves to something for plan-time testing and as a base for
your own bake. Mirrors `proxmox-control-plane`'s `proxmox_template_vm_id` convention.

### Keeping user data under EC2's limit

EC2 rejects `RunInstances` when decoded user data exceeds 16384 bytes. Static content
therefore stays out of the payload: the bootstrap program is baked into the node image,
and with `trusted_ca_in_image` a CA is too. A precondition on the instance names those
levers when the limit is exceeded.

## Scope

The module provisions the **node and only what is intrinsic to it** — the EC2 instance, its
own security group, its IAM role/instance-profile, and (optionally) a DNS record. It **never
creates network fabric** (VPC, subnet, internet gateway, NAT, route tables); you plug in
existing networking, or it falls back to the account's default VPC.

## Topology

- **`control_plane_count`** — `1` (default), `3`, or `5`. `2` and `4` are rejected (no
  fault-tolerance benefit, split-brain risk). `3`/`5` place one control-plane node per
  availability zone (requires `control_plane_subnets`, a map of AZ -> subnet id, spanning at
  least 3 distinct AZs; fewer fails plan with a clear error) behind an internal NLB on 6443;
  `registration_address` becomes the NLB's DNS name. The first control-plane node probes that
  address at boot: reachable → join the existing quorum; unreachable → initialize (RKE2 has no
  `--cluster-init` flag — the first server is simply the one whose config omits a `server:`
  join address — so replacing it is always a safe rejoin, never a second initialization).
- **`cluster_type`** — `all_in_one` (default; control-plane node stays schedulable) or
  `dedicated_control_plane` (tainted `CriticalAddonsOnly=true:NoExecute`; for use once node
  pools exist). Derived from this explicit intent, never from node counts — node pools are
  separate Terraform state this module cannot see.
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
- Additionally set `hosted_zone_id` to have the module create the wildcard A record in that
  Route53 zone.
- If you don't pass `hosted_zone_id`, the module creates **no** DNS record — register the
  `wildcard_dns_name` output at the `cluster_ip` in whatever DNS you run (Route53, a local
  resolver, RFC2136, external-dns, or an `sslip.io`-style fallback).

## Access

Zero inbound beyond `ingress_ports` (default 80/443/6443) from `allowed_ingress_cidrs`; no SSH.
IMDSv2 is enforced. Operator access to the node is via AWS SSM (the IAM role attaches
`AmazonSSMManagedInstanceCore`) — there is no inbound shell port.

## Join flow (workers and, later, additional control-plane nodes)

This module generates its own join tokens directly (`random_password.server_token` /
`random_password.agent_token`), matching `proxmox-control-plane`'s precedent. `cluster_token`
(the **server token**, used by both genesis and every `server-join` node) and
`cluster_agent_token` (the **agent token**, mirrored into an SSM `SecureString` workers fetch via
their own instance IAM role) are never exposed as raw values outside the module. Workers receive
only the agent token, so a compromised worker cannot rejoin as control-plane/etcd.

Two security groups carry east-west traffic, both created here: `aws_security_group.cluster`
(self-referencing, every member, exposed as `cluster_security_group_id` for a future
`aws-node-pool` unit to attach to by id) and `control_plane_etcd` (control-plane-only, scopes
etcd 2379-2380 so workers can never reach it). `registration_address` is what a joining node's
`--server` flag targets — for `control_plane_count = 1` this is the control-plane node's private
IP.

## HA control plane (`control_plane_count` > 1)

`control_plane_subnets` (a map of AZ -> subnet id) is required once `control_plane_count > 1` —
the module does not auto-discover multi-AZ subnets. Its keys ARE the AZs, so a caller cannot
accidentally supply two subnets in the same AZ. Pass at least 3 entries spanning at least 3
distinct AZs; fewer fails plan explicitly rather than silently forming a weaker quorum.

Once `control_plane_count > 1`, the single `subnet_id`/`subnet_name` above is unused for
control-plane placement — the module's own VPC (for its security groups and the NLB target
group) is derived from `control_plane_subnets` itself, so it can never disagree with where the
instances actually launch.

The genesis node is unchanged in shape from `control_plane_count = 1`. Additional control-plane
nodes (`server-join`) bootstrap concurrently with it and join via the NLB, retrying the
registration endpoint the same way a worker retries its join target; node-bootstrap's own
staggered, self-healing retry handles the one genuine etcd constraint (one non-voting learner at
a time) among the joining siblings. Argo/platform GitOps inputs are only ever passed to the
genesis node, so platform bootstrap manifests never race on more than one server.

## Container Network Interface (CNI)

`cni` is `null` by default, resolving to `"cilium"` regardless of topology. `"default"`
(Canal/flannel+Calico) remains selectable as an escape hatch for a consumer-supplied playbook
targeting a different OS, but is not viable on AlmaLinux 10 (this project's only supported OS):
its kernel dropped the legacy `br_netfilter`/`xt_conntrack`/`xt_comment` modules flannel and
Felix's iptables dataplane require — confirmed via a real apply, not theoretical. On a
single-node cluster, the Cilium operator's replica count is set to `1` (chart default `2`) so
the second replica doesn't sit permanently `Pending`. The cluster security group's
self-referencing all-protocol rule already covers every CNI's traffic, so switching `cni` never
requires a security-group change.

## Registration endpoint modes (`endpoint_mode`)

Only relevant once `control_plane_count > 1` — a single control-plane node has no registration
endpoint at all.

- **`loadbalancer`** (default) — an internal NLB across all control-plane nodes on 6443.
- **`dns`** — one Route53 A record per control-plane node under a shared name
  (`cp.<cluster_name>.<cluster_domain>`), multivalue-answer routing, each backed by a
  `CLOUDWATCH_METRIC` health check on that instance's own EC2 status-check alarm (Route53's
  public health checkers can't reach a private VPC IP directly, so the alarm is the bridge).
  Requires `cluster_domain` and a resolvable hosted zone. Cheaper than an NLB; failover is
  TTL-bound (`ttl = 10`), not instant.
- **`static`** — creates no load balancer or DNS record; `static_registration_address` is used
  verbatim. For a consumer that already runs its own front end.

## Inputs

See `variables.tf`. Environment-specific values are inputs — none are baked in. Compute sizing
is AWS-native: `instance_type` (bundles vCPU+memory), `root_volume_size_gb`, `root_volume_type`.
`os_image_ami_id`/`os_image_name` default to the latest stock AlmaLinux 10 for the derived
architecture (no RKE2 baked in — see "Boot flow"). Join tokens and the cluster security group are **not** inputs — this
module generates and owns them directly (see "Join flow").

## Outputs

Standardized across provider modules: `instance_id`, `cluster_ip`, `cluster_fqdn` (null when
IP-only), `node_provider` (`"aws"`), `node_control_ref`. Plus `wildcard_dns_name`, `aws_region`,
`node_arch`, `effective_ami_id`, `vpc_id`, `subnet_id`, `node_iam_role_name`. Join flow:
`registration_address` (a node's private IP for `control_plane_count = 1`, otherwise shaped by
`endpoint_mode`), `control_plane_node_refs` (every control-plane node, not just the first),
`cluster_security_group_id`, and `agent_token_ssm_parameter`. A future `aws-node-pool` unit reads
the last two via a `dependency "control_plane"` block to attach workers to the cluster SG and
fetch the agent token. Raw join token values are never outputs — workers only need the SSM
parameter name.

## Out of scope (lives in the consumer repo)

Team-specific operational policy is **not** in this module — e.g. a schedule that stops and
starts the nodes. `aws-cluster` has one, `power_schedule`. Used on its own, this module needs an
`aws_scheduler_schedule` in your own config referencing the `instance_id` output.

## Testing

    cd modules/aws-control-plane
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS is run by the operator from a consumer repo.
