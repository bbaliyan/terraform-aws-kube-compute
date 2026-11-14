> **Release mirror, generated -- do not edit here.** Built from
> [kube-compute](https://github.com/bbaliyan/kube-compute)'s `modules/aws-cluster` and the
> modules it uses, on every kube-compute release that changes them. Issues and pull requests
> go to kube-compute. Published on the OpenTofu Registry as `bbaliyan/kube-compute/aws`.
>
> | Module | Built from |
> |---|---|
> | `.` | `modules/aws-cluster` |
> | `modules/control-plane` | `modules/aws-control-plane` |
> | `modules/node-pool` | `modules/aws-node-pool` |
> | `modules/static-node` | `modules/aws-static-node` |
> | `modules/boot-steps` | `modules/aws-boot-steps` |
> | `modules/node-iam` | `modules/aws-node-iam` |
> | `modules/node-bootstrap` | `modules/node-bootstrap` |

# aws-cluster

One Terraform state for a whole AWS cluster: the control plane from
[`aws-control-plane`](./modules/control-plane/README.md), named workers from
[`aws-static-node`](./modules/static-node/README.md), and autoscaled workers from
[`aws-node-pool`](./modules/node-pool/README.md). Every input `aws-control-plane`
accepts is available here unchanged.

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/aws-cluster"

  cluster_name          = "example"
  cluster_type          = "dedicated_control_plane"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/24"]
  subnet_names          = ["private-az1", "private-az2"]
  os_image_name         = "almalinux10-*-kube-image-v1.36.2-*"
  instance_type         = "t4g.large"

  static_nodes = {
    platform = { instance_type = "t3a.xlarge", root_volume_size_gb = 40 }
  }
  platform_node_group = "platform"

  autoscaled_nodes = {
    workers = {
      instance_types = ["m7a.large", "m7a.xlarge", "m7a.2xlarge"]
      max_cpu_cores  = 16
      max_memory_gib = 64
    }
  }

  power_schedule = { stop_time = "20:00", timezone = "UTC" }
}
```

## Names

`cluster_name` is the cluster's identity: tags, resource names, the agent token parameter,
and node names such as `cp-example-1` and `platform-example-1`. It has to be unique in the
account and region. Where one cluster design is deployed more than once, put what tells
the copies apart in the name: `app-red`, `app-blue`.

The DNS name is `cluster_name` too, so `cluster_name = "app-red"` and `cluster_domain = "red.example.internal"`
serve the cluster at `app-red.red.example.internal`.

A cluster name may start with a letter or a digit: `app-red` and `7c-demo` both work.

### Your own node names

Where nodes must follow a naming rule of their own, for example to join a Windows
domain, whose computer names are at most 15 characters, pass a template.
`control_plane_node_name_template` names the control-plane nodes, and each `static_nodes`
group takes its own `node_name_template`. In a template, `{zone}` becomes the last letter
of the node's availability zone and `{number}` the node's number as two digits:

```hcl
control_plane_node_name_template = "demo-{zone}-cp{number}"

static_nodes = {
  platform = { node_count = 2, node_name_template = "demo-{zone}-wk{number}" }
}
```

That gives `demo-a-cp01`, `demo-a-wk01` and `demo-a-wk02` in zone a. The name is the node's
hostname, its Kubernetes node name and its Name tag. A template must contain `{number}`, and no
two templates may be the same, so nodes never share a name. A name may be up to 63 characters;
keeping it within a stricter limit, such as Windows' 15, is up to you. `{zone}` comes from the
availability zone's name, so `control_plane_subnets` must be keyed by zone names such as
`eu-west-1a`, not zone IDs. Autoscaled nodes keep the names AWS gives them.

Changing a template changes the user data of the nodes. A running node keeps its old
hostname and Kubernetes node name until it is replaced. See "User data changes".

## Nodes

| Kind | Input | For |
|---|---|---|
| Control plane | `cluster_type`, `instance_type` | RKE2; also workloads unless `dedicated_control_plane` |
| Static | `static_nodes` | Capacity the cluster must always have |
| Autoscaled | `autoscaled_nodes` | Pods that fit nowhere else |

Static and autoscaled nodes launch into the control plane's subnet, so the
cluster stays in one availability zone: an EBS volume cannot cross zones. A
static group can take its own `subnet_id` as a deliberate exception.

`subnet_names` is a list of candidates for that one subnet, not a set to spread across, so
the candidates may sit in different zones. A new cluster goes into the first candidate
with a free address for the control plane and every static node that shares its subnet. A
candidate with some free addresses but too few is skipped, rather than chosen and failing
the apply partway. The choice is kept in state, so the cluster stays in its subnet. No
plan makes the choice again, however full that subnet becomes or however the list changes.
Autoscaled workers are not counted, since they launch later; one that finds the subnet
full fails to join until addresses free up.

To choose again on purpose, replace the stored choice:

```sh
tofu apply -replace='module.<name>.module.control_plane.terraform_data.subnet_choice[0]'
```

If the new choice is a different subnet, the apply replaces every node. You can
also destroy the cluster and apply again.

Every node carries `kube-compute.io/node-group=<key>`: the static group's name, or
the autoscaled role's, whatever the node's size. `node_taints` keeps other pods
off; pods that belong there need a matching toleration.

## Argo CD manifest

The first control-plane node clones the platform ref (`gitops_platform_repo_url` at `gitops_platform_revision`) before RKE2 starts. It takes the Cilium and Argo CD manifests from `bootstrap/rendered/` in the clone. The AMI must hold git. If `gitops_platform_enabled` is false, set `gitops_platform_repo_url`, because the node still reads the Cilium manifest from it. See [`node-bootstrap`](./modules/node-bootstrap/README.md).

After Cilium is Ready, the first server removes the Cilium file from the RKE2 manifests directory, even when GitOps is off. A later server restart then no longer applies it again.

## Platform node

`platform_node_group` names the static group that runs the platform stack:

- its components are pinned to that group;
- it alone takes the security group carrying `ingress_ports`, since Traefik runs there;
- the wildcard DNS record points at it;
- `platform_node_iam_role_name` resolves to its role.

Without it, all of that stays on the control plane.

## Autoscaling

Each `autoscaled_nodes` entry is a role listing the instance types it may
launch. Every type is its own EC2 Auto Scaling group starting at zero, because
cluster-autoscaler requires one shape per group. The platform Application then
runs:

- **cluster-autoscaler**, which adds a node for a pod that fits nowhere else, of the
  size leaving the least capacity idle, and removes unneeded nodes;
- **the AWS cloud controller manager's node lifecycle controller**, which deletes the
  Node object of a terminated instance so its pods and volumes can move. The autoscaler
  never deletes Node objects itself.

Each one authenticates as the node it runs on. The autoscaler runs on the platform node,
the cloud controller manager on the control plane, and the first node back after a stop.
This module gives each role its permissions. Scaling is limited to this cluster's own
groups.


Both find a node's instance through its providerID, so every node of an autoscaled cluster
registers `aws:///<zone>/<instance-id>`. **Adding the first group, or removing the last,
changes the user data of the control plane and static nodes.** A running node keeps its
old registration until it is replaced. Replace those nodes on purpose. See "User data
changes".

### Limits

A role's `max_cpu_cores` and `max_memory_gib` cap the vCPUs and memory its nodes may add
up to, whichever sizes the autoscaler picks. The autoscaler's own `--cores-total` and
`--memory-total` count every node in the cluster. So this module passes every role's caps
plus the control plane and static nodes, as read from AWS. `cluster_autoscaler_limits`
shows the result. A pod that would need more stays Pending.

Those totals are cluster-wide: with several roles, the autoscaler enforces the sum of
their caps. Each Auto Scaling group's maximum is how many of its type fit its role's caps
alone. An instance type larger than its role's caps fails the plan.

## Power schedule

`power_schedule` says when the cluster's nodes run. `days` names the days it runs,
in EventBridge Scheduler's form (`MON-FRI`, `MON,WED,FRI`); it is off on the
rest. Unset, it runs every day.

At `stop_time` on each of those days it stops the control plane and static nodes. At the
same moment it sets every autoscaled group to zero, because an instance in an Auto Scaling
group cannot be stopped. Those schedules sit in the `<cluster_name>-to-zero` schedule
group, one per role and instance type. Nothing is left running to scale the groups back
up. When the cluster is started again, the lifecycle controller removes the old nodes and
the autoscaler adds new ones as pods need them.

Nothing starts the cluster unless `start_time` is set, in which case the
`<cluster_name>-node-start` schedule starts the control plane and static nodes.
When `start_time` is earlier than `stop_time`, that is on the same day. When it is
later, the hours cross midnight and each day's run starts the evening before:

```hcl
power_schedule = {
  days       = "MON-FRI"
  start_time = "22:00"
  stop_time  = "18:00"
  timezone   = "UTC"
}
```

This runs Sunday 22:00 to Monday 18:00, up to Thursday 22:00 to Friday 18:00, and
is off from Friday afternoon to Sunday evening. The stop fires `MON-FRI` and the
start `SUN-THU`. A time zone without daylight saving, such as UTC, keeps those
hours the same all year in every location.

`all_instance_ids` lists the instances Terraform owns individually, also as
`local.all_instance_ids` for files a consumer generates into this directory.

## Graceful shutdown

`graceful_shutdown` is how long kubelet holds up an OS shutdown while it evicts pods. A
node stopped by `power_schedule`, scaled in by the autoscaler or simply terminated then
stops its workloads instead of having them killed with it. `critical_seconds` is the part
of that window reserved for critical pods.

Three settings have to agree, and every node gets all three. They are a kubelet drop-in
carrying the grace period, a `config.yaml.d` fragment pointing kubelet at that drop-in,
and a logind override raising `InhibitDelayMaxSec`. The fragment is needed because
`shutdownGracePeriod` has no command-line flag, so `kubelet-arg` cannot reach it. The
logind override matters just as much: left at its five-second default, logind caps
kubelet's window to five seconds and the eviction never finishes.

Keep the total well under the two minutes a cloud allows an instance before it pulls the
power. Leave room inside it for the longest `terminationGracePeriodSeconds` among the pods
that run here. Null disables the feature.

It is on by default and adds files to every node's user data. A running node gets
them only when it is replaced. See "User data changes".

A spot interruption is only partly covered. The OS shutdown arrives at the end of the
two-minute warning rather than at its start, so this is a backstop. Draining on the
warning itself needs a node termination handler running in the cluster.

## OS updates

`os_auto_updates` has every node install OS updates with `dnf-automatic` daily at 06:00 and 15 minutes after every boot. So nodes stopped overnight by `power_schedule` update when they start. It never reboots: kube-platform's Node OS Updates dashboard shows the nodes whose updates
need one, and rebooting them is left to whoever runs the cluster. RKE2's own packages
are excluded from dnf, so system-upgrade-controller stays the only thing that changes
the Kubernetes version.

It is on by default and changes every node's user data. A running node gets it only
when it is replaced. See "User data changes".

## Volumes on destroy

A destroy deletes each node's root volume with its instance. It deletes no data
volume by itself, including one still attached to a node.

`orphan_volume_cleanup` deletes the cluster's dynamically provisioned EBS volumes once its
nodes are gone. A destroy never deletes a PVC, so the CSI driver is never asked to release
the volume behind it. The volume is left detached and billed. Nothing picks it up later,
so each destroy adds another set.

The sweep matches volumes tagged `ClusterName` with this cluster's name, which the
platform chart is expected to apply. It deletes only volumes that are `available`. It
waits first for any still detaching, since an Auto Scaling group terminates its instances
after Terraform has stopped waiting on it. Whoever runs the destroy needs
`ec2:DescribeVolumes` and `ec2:DeleteVolume`.

Turn it off where a volume is meant to outlive its cluster. A PersistentVolume kept with
`reclaimPolicy: Retain` carries the same tag and would be swept with the rest.

Keep `orphan_volume_cleanup` on to delete data volumes tagged with the cluster's
`ClusterName`. Callers of `aws-control-plane` without `aws-cluster` keep every
data volume on destroy.

## User data changes

Most inputs end up in a node's user data: Helm parameters, names,
`graceful_shutdown`, `os_auto_updates`, and whether the cluster autoscales. A
module upgrade can change it too. cloud-init reads user data only at the first
boot, so a running node never applies a change.

A changed user data does not touch a running control-plane or static node. To apply
it, replace the node on purpose. The addresses are:

- First control-plane node: `module.<name>.module.control_plane.aws_instance.control_plane["0"]`
- Other control-plane nodes: `module.<name>.module.control_plane.aws_instance.control_plane["1"]`
- Static node: `module.<name>.module.static_nodes["<group>"].aws_instance.node["1"]`

> **Warning:** Replacing a single-node cluster loses the cluster.

For a control-plane node on a multi-node cluster, replace one node at a time:

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

For a static node, drain it, delete the Kubernetes node, replace it, and verify that
it is `Ready`.

Autoscaled nodes are not affected: an Auto Scaling group gives new user data only to
the instances it launches later.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | CIDR blocks allowed inbound to the cluster ports from outside the cluster — the networks you administer/reach the cluster from. Required — environment-specific. | `list(string)` | n/a | yes |
| <a name="input_autoscaled_nodes"></a> [autoscaled\_nodes](#input\_autoscaled\_nodes) | Roles the autoscaler fills. Each instance type is an Auto Scaling group from zero in the control-plane subnet, labelled kube-compute.io/node-group=<role>. max\_cpu\_cores and max\_memory\_gib cap a role. Adding the first role or removing the last replaces the control plane and static nodes. | <pre>map(object({<br/>    instance_types      = list(string)<br/>    max_cpu_cores       = number<br/>    max_memory_gib      = number<br/>    os_image_ami_id     = optional(string)<br/>    root_volume_size_gb = optional(number, 20)<br/>    root_volume_type    = optional(string, "gp3")<br/>    node_labels         = optional(map(string), {})<br/>    node_taints         = optional(list(string), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region the cluster runs in. Exposed as an output so the SSM control-plane scripts (and node pools) know which region to target. Does NOT configure the provider — the caller sets the provider region; pass the same value here. | `string` | n/a | yes |
| <a name="input_cert_mode"></a> [cert\_mode](#input\_cert\_mode) | Certificate issuer mode deployed by kube-platform. 'selfsigned' (default), 'byo', or 'acme'. | `string` | `"selfsigned"` | no |
| <a name="input_cluster_domain"></a> [cluster\_domain](#input\_cluster\_domain) | Optional DNS suffix for the cluster, e.g. 'example.internal'. When set, the FQDN is <cluster\_name>.<cluster\_domain> and the wildcard is *.<cluster\_name>.<cluster\_domain>. Null = node is reachable by IP only. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter or digit. | `string` | n/a | yes |
| <a name="input_cluster_type"></a> [cluster\_type](#input\_cluster\_type) | Cluster topology intent: 'all\_in\_one' (control-plane nodes stay schedulable) or 'dedicated\_control\_plane' (control-plane nodes are tainted so user workloads run only on separate node pools). | `string` | `"all_in_one"` | no |
| <a name="input_control_plane_count"></a> [control\_plane\_count](#input\_control\_plane\_count) | Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain. | `number` | `1` | no |
| <a name="input_control_plane_node_name_template"></a> [control\_plane\_node\_name\_template](#input\_control\_plane\_node\_name\_template) | Name for each control-plane node: hostname, Kubernetes node name and Name tag. {zone} is the last letter of the availability zone. {number} is the node number as two digits. Null keeps cp-<cluster\_name>-<n>. | `string` | `null` | no |
| <a name="input_control_plane_subnets"></a> [control\_plane\_subnets](#input\_control\_plane\_subnets) | Map of availability zone -> subnet id for control-plane placement, required when control\_plane\_count > 1. Ignored when control\_plane\_count = 1 — use subnet\_id/subnet\_name instead. | `map(string)` | `null` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Upstream DNS resolver IPs. They give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record. Null keeps the kubelet default. 169.254.169.253 is the Amazon-provided resolver. | `list(string)` | `null` | no |
| <a name="input_endpoint_mode"></a> [endpoint\_mode](#input\_endpoint\_mode) | How joining nodes reach the registration endpoint once control\_plane\_count > 1 (ignored for control\_plane\_count = 1): "loadbalancer" (default) creates an internal NLB; "dns" creates Route53 multivalue-answer A records; "static" uses static\_registration\_address verbatim. | `string` | `"loadbalancer"` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional tags applied to every AWS resource this module creates (EC2 instance, root EBS volume, security group, IAM role), and forwarded to node-bootstrap so platform-managed resources (e.g. CSI-provisioned storage) can tag themselves consistently. | `map(string)` | `{}` | no |
| <a name="input_gitops_platform_enabled"></a> [gitops\_platform\_enabled](#input\_gitops\_platform\_enabled) | Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application. | `bool` | `true` | no |
| <a name="input_gitops_platform_repo_url_override"></a> [gitops\_platform\_repo\_url\_override](#input\_gitops\_platform\_repo\_url\_override) | Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin. | `string` | `null` | no |
| <a name="input_gitops_platform_revision_override"></a> [gitops\_platform\_revision\_override](#input\_gitops\_platform\_revision\_override) | Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default. | `string` | `null` | no |
| <a name="input_gitops_workloads_path"></a> [gitops\_workloads\_path](#input\_gitops\_workloads\_path) | Path within the workloads repo Argo CD applies. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"."` | no |
| <a name="input_gitops_workloads_repo_url"></a> [gitops\_workloads\_repo\_url](#input\_gitops\_workloads\_repo\_url) | Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application. | `string` | `null` | no |
| <a name="input_gitops_workloads_revision"></a> [gitops\_workloads\_revision](#input\_gitops\_workloads\_revision) | Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"main"` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet delays an OS shutdown to evict pods. critical\_seconds is the part reserved for critical pods and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables it. Keep the total well under 2 minutes. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_hosted_zone_id"></a> [hosted\_zone\_id](#input\_hosted\_zone\_id) | Route53 hosted zone ID. Alternative to hosted\_zone\_name. Requires cluster\_domain to be set. Null = create no record; register DNS yourself using the wildcard\_dns\_name output. | `string` | `null` | no |
| <a name="input_hosted_zone_name"></a> [hosted\_zone\_name](#input\_hosted\_zone\_name) | Name of the Route53 private hosted zone. Alternative to hosted\_zone\_id. Requires cluster\_domain to be set. | `string` | `null` | no |
| <a name="input_ingress_ports"></a> [ingress\_ports](#input\_ingress\_ports) | TCP ports opened on the control-plane security group: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH). | `list(number)` | <pre>[<br/>  80,<br/>  443,<br/>  6443<br/>]</pre> | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type (bundles vCPU + memory) for the control-plane node(s). CPU arch (arm64/x86\_64) is derived from the family prefix for AMI selection. | `string` | `"m7g.medium"` | no |
| <a name="input_orphan_volume_cleanup"></a> [orphan\_volume\_cleanup](#input\_orphan\_volume\_cleanup) | Delete the cluster's dynamically provisioned EBS volumes on destroy, found by their ClusterName tag. Turn it off where a volume must outlive the cluster, for example a Retain PersistentVolume. With it off, a destroy keeps every data volume. | `bool` | `true` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Install OS updates with dnf-automatic on every node, daily, without rebooting. RKE2 packages are excluded, because system-upgrade-controller upgrades them. needs-restarting (yum-utils) reports a due reboot. False leaves packages as baked. | `bool` | `true` | no |
| <a name="input_os_image_ami_id"></a> [os\_image\_ami\_id](#input\_os\_image\_ami\_id) | AMI ID of a kube-images build for the control-plane node(s). Set this or os\_image\_name. The image must have RKE2 baked in, and no check compares the AMI with what is baked in it. | `string` | `null` | no |
| <a name="input_os_image_name"></a> [os\_image\_name](#input\_os\_image\_name) | AMI name of a kube-images build for the control-plane nodes. Set this or os\_image\_ami\_id, which wins if set. Accepts EC2 Name wildcards (*, ?); a pattern without the build date picks the newest match. | `string` | `null` | no |
| <a name="input_platform_extra_helm_parameters"></a> [platform\_extra\_helm\_parameters](#input\_platform\_extra\_helm\_parameters) | Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. | `map(string)` | `{}` | no |
| <a name="input_platform_helm_values_object"></a> [platform\_helm\_values\_object](#input\_platform\_helm\_values\_object) | Arbitrary object forwarded to the platform Application as helm.valuesObject. | `any` | `null` | no |
| <a name="input_platform_node_group"></a> [platform\_node\_group](#input\_platform\_node\_group) | static\_nodes key of the group that runs the platform stack, ingress included. That group's node-group label pins the platform components, it alone takes the ingress security group, and the wildcard DNS record points at it. Null keeps all of that on the control plane. | `string` | `null` | no |
| <a name="input_power_schedule"></a> [power\_schedule](#input\_power\_schedule) | When nodes run. days uses EventBridge Scheduler form (MON-FRI); unset means every day. At stop\_time the control plane and static nodes stop and autoscaled groups scale to zero. start\_time starts them again; without it the cluster stays stopped. Times are HH:MM in timezone. Null: always running. | <pre>object({<br/>    stop_time  = string<br/>    timezone   = string<br/>    start_time = optional(string)<br/>    days       = optional(string)<br/>  })</pre> | `null` | no |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream. | `string` | `null` | no |
| <a name="input_root_volume_size_gb"></a> [root\_volume\_size\_gb](#input\_root\_volume\_size\_gb) | Root EBS volume size (GB) for the control-plane node(s). Covers OS + container image cache. | `number` | `20` | no |
| <a name="input_root_volume_type"></a> [root\_volume\_type](#input\_root\_volume\_type) | Root EBS volume type (gp3, gp2, io2, ...) for the control-plane node(s). | `string` | `"gp3"` | no |
| <a name="input_static_nodes"></a> [static\_nodes](#input\_static\_nodes) | Named worker node groups keyed by group name (e.g. 'platform'), each created through aws-static-node with the cluster's identity, join address and security groups. For capacity the cluster must always have. subnet\_id defaults to the control plane's. Empty (the default) creates none. | <pre>map(object({<br/>    node_count            = optional(number, 1)<br/>    instance_type         = optional(string, "m7g.medium")<br/>    subnet_id             = optional(string)<br/>    os_image_ami_id       = optional(string)<br/>    os_image_name         = optional(string)<br/>    root_volume_size_gb   = optional(number, 20)<br/>    root_volume_type      = optional(string, "gp3")<br/>    node_labels           = optional(map(string), {})<br/>    node_taints           = optional(list(string), [])<br/>    attach_ebs_csi_policy = optional(bool, true)<br/>    trusted_ca_pem        = optional(string)<br/>    registry_mirror_url   = optional(string)<br/>    dns_servers           = optional(list(string))<br/>    extra_tags            = optional(map(string), {})<br/>    node_name_template    = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_static_registration_address"></a> [static\_registration\_address](#input\_static\_registration\_address) | Consumer-supplied registration endpoint address, used verbatim as registration\_address when endpoint\_mode = "static". Ignored otherwise. | `string` | `null` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet the control-plane node (control\_plane\_count = 1) launches into. Null = the module falls back to a subnet in the account's default VPC. | `string` | `null` | no |
| <a name="input_subnet_name"></a> [subnet\_name](#input\_subnet\_name) | Name tag of the subnet to launch the control-plane node into (control\_plane\_count = 1 only). Alternative to subnet\_id. | `string` | `null` | no |
| <a name="input_subnet_names"></a> [subnet\_names](#input\_subnet\_names) | Candidate subnets by Name tag, in order of preference. The first with a free address for the control plane and each static node without its own subnet\_id wins, and the choice stays in state. To choose again, replace terraform\_data.subnet\_choice[0] in the control plane. List form of subnet\_name. | `list(string)` | `null` | no |
| <a name="input_trusted_ca_in_image"></a> [trusted\_ca\_in\_image](#input\_trusted\_ca\_in\_image) | Whether the node image already carries trusted\_ca\_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. If true, user data omits the PEM, but the value is still used for the containerd TLS pin. The boot program fails if the file is missing. | `bool` | `false` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive. | `string` | `null` | no |
| <a name="input_vpc_name"></a> [vpc\_name](#input\_vpc\_name) | Name tag of the VPC. Pair with subnet\_name to scope the subnet lookup to a specific VPC. Ignored when subnet\_id is used. | `string` | `null` | no |
| <a name="input_workloads_extra_helm_parameters"></a> [workloads\_extra\_helm\_parameters](#input\_workloads\_extra\_helm\_parameters) | Helm parameters forwarded verbatim to the workloads Application. See node-bootstrap for full description. | `map(string)` | `{}` | no |
| <a name="input_workloads_helm_values_object"></a> [workloads\_helm\_values\_object](#input\_workloads\_helm\_values\_object) | Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations. | `any` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_agent_token_ssm_parameter"></a> [agent\_token\_ssm\_parameter](#output\_agent\_token\_ssm\_parameter) | SSM Parameter Store name (SecureString) holding the agent join token. |
| <a name="output_all_instance_ids"></a> [all\_instance\_ids](#output\_all\_instance\_ids) | Every EC2 instance Terraform owns individually: the control-plane node(s) plus every static node. Excludes autoscaled nodes, which can be removed but not stopped. |
| <a name="output_autoscaled_nodes"></a> [autoscaled\_nodes](#output\_autoscaled\_nodes) | Map of role -> {autoscaling\_groups, availability\_zone, node\_iam\_role\_name, node\_labels, node\_taints}, where autoscaling\_groups maps each instance type to its group's {name, arn, max\_size, node\_arch}. |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | Region the cluster runs in (the verb-scripts need it for SSM calls). |
| <a name="output_cluster_autoscaler_limits"></a> [cluster\_autoscaler\_limits](#output\_cluster\_autoscaler\_limits) | The cluster-wide totals passed to cluster-autoscaler: every role's max\_cpu\_cores and max\_memory\_gib plus the control plane and static nodes. Null without autoscaled\_nodes. |
| <a name="output_cluster_fqdn"></a> [cluster\_fqdn](#output\_cluster\_fqdn) | API server / kubeconfig FQDN, or null when no cluster\_domain was given. |
| <a name="output_cluster_ip"></a> [cluster\_ip](#output\_cluster\_ip) | Genesis control-plane node's private IP. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Cluster name passed to the module. |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Self-referencing security group id shared by every cluster member. |
| <a name="output_control_plane_node_refs"></a> [control\_plane\_node\_refs](#output\_control\_plane\_node\_refs) | Map of control-plane node name -> {instance\_id, provider}. |
| <a name="output_effective_ami_id"></a> [effective\_ami\_id](#output\_effective\_ami\_id) | AMI ID actually used for the control-plane node(s) (os\_image\_ami\_id, or the os\_image\_name lookup). |
| <a name="output_hosted_zone_id"></a> [hosted\_zone\_id](#output\_hosted\_zone\_id) | Route53 zone the cluster's records live in, or null when no domain is configured. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | Provider-native node ID of the genesis control-plane instance. |
| <a name="output_node_arch"></a> [node\_arch](#output\_node\_arch) | CPU architecture reported by AWS for instance\_type. |
| <a name="output_node_control_ref"></a> [node\_control\_ref](#output\_node\_control\_ref) | Genesis instance ID, for control-plane verb-scripts that need a single node reference (SSM send-command/start-session). |
| <a name="output_node_iam_role_name"></a> [node\_iam\_role\_name](#output\_node\_iam\_role\_name) | IAM role name attached to the control-plane node(s). Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO). |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier ('aws'). |
| <a name="output_platform_node_iam_role_name"></a> [platform\_node\_iam\_role\_name](#output\_platform\_node\_iam\_role\_name) | IAM role of the nodes running the platform stack: platform\_node\_group's, or the control plane's when none is set. Policies for platform controllers that authenticate as their node, such as External Secrets, belong on it. |
| <a name="output_registration_address"></a> [registration\_address](#output\_registration\_address) | Address workers/joining servers use to reach the cluster API. |
| <a name="output_static_nodes"></a> [static\_nodes](#output\_static\_nodes) | Map of group name -> {node\_provider, node\_refs, instance\_ids, private\_ips, availability\_zone, node\_arch, node\_iam\_role\_name, node\_labels, node\_taints}. |
| <a name="output_subnet_id"></a> [subnet\_id](#output\_subnet\_id) | Subnet ID the genesis control-plane node launched into. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC ID the control plane launched into. |
| <a name="output_wildcard_dns_name"></a> [wildcard\_dns\_name](#output\_wildcard\_dns\_name) | Wildcard hostname for cluster services, or null when no cluster\_domain was given. |
| <a name="output_workload_node_iam_role_names"></a> [workload\_node\_iam\_role\_names](#output\_workload\_node\_iam\_role\_names) | IAM roles of every node a workload pod can be scheduled on. Policies a workload authenticates with through its node belong on each of them. |
<!-- END_TF_DOCS -->

## Testing

    cd modules/aws-cluster
    tofu init -backend=false && tofu test
