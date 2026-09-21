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
> | `modules/node-bootstrap` | `modules/node-bootstrap` |

# aws-cluster

One Terraform state for a whole AWS cluster: the control plane from
[`aws-control-plane`](../aws-control-plane/README.md), named workers from
[`aws-static-node`](../aws-static-node/README.md), and autoscaled workers from
[`aws-node-pool`](../aws-node-pool/README.md). Every input `aws-control-plane`
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

  nightly_stop = { time = "20:00", timezone = "Australia/Sydney" }
}
```

## Nodes

| Kind | Input | For |
|---|---|---|
| Control plane | `cluster_type`, `instance_type` | RKE2; also workloads unless `dedicated_control_plane` |
| Static | `static_nodes` | Capacity the cluster must always have |
| Autoscaled | `autoscaled_nodes` | Pods that fit nowhere else |

Static and autoscaled nodes launch into the control plane's subnet, so the
cluster stays in one availability zone: an EBS volume cannot cross zones. A
static group can take its own `subnet_id` as a deliberate exception.

Every node carries `kube-compute.io/node-group=<key>`: the static group's name, or
the autoscaled role's, whatever the node's size. `node_taints` keeps other pods
off; pods that belong there need a matching toleration.

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

- **cluster-autoscaler**, which adds a node for a pod that fits nowhere else,
  of the size leaving the least capacity idle, and removes nodes no longer
  needed;
- **the AWS cloud controller manager's node lifecycle controller**, which
  deletes the Node object of a terminated instance so its pods and volumes can
  move. The autoscaler never deletes Node objects itself.

Each authenticates as the node it runs on: the autoscaler on the platform node,
the cloud controller manager on the control plane, the first node back after a
stop. This module gives each role its permissions, and scaling is limited to this
cluster's own groups.

Both find a node's instance through its providerID, so every node of an
autoscaled cluster registers `aws:///<zone>/<instance-id>`. **Adding the first
group, or removing the last, replaces the control plane and static nodes.**

### Limits

A role's `max_cpu_cores` and `max_memory_gib` cap the vCPUs and memory its nodes
may add up to, whichever sizes the autoscaler picks. The autoscaler's own
`--cores-total` and `--memory-total` count every node in the cluster, so this
module passes every role's caps plus the control plane and static nodes, as read
from AWS; `cluster_autoscaler_limits` shows the result. A pod that would need
more stays Pending.

Those totals are cluster-wide: with several roles, the autoscaler enforces the
sum of their caps. Each Auto Scaling group's maximum is how many of its type fit
its role's caps alone, and an instance type larger than its role's caps fails the
plan.

## Nightly stop

`nightly_stop` stops the control plane and static nodes at the given time, and at
the same moment sets every autoscaled group to zero, because an instance in an
Auto Scaling group cannot be stopped. Those schedules sit in the
`<cluster_name>-to-zero` schedule group, one per role and instance type. Nothing is left running to scale the groups
back up. When the cluster is started again, the lifecycle controller removes the
old nodes and the autoscaler adds new ones as pods need them.

Nothing starts the cluster unless `start_time` is set, in which case the
`<cluster_name>-node-start` schedule starts the control plane and static nodes at
that time. `days` limits the stop to days of the week, in EventBridge Scheduler's
form, and `start_days` the start, defaulting to `days`:

```hcl
nightly_stop = { time = "16:10", days = "MON-FRI", start_time = "20:40", start_days = "SUN-THU", timezone = "UTC" }
```

Both are clock times on the listed days, so hours that cross midnight start on
the day before they stop: here the cluster runs Sunday 20:40 to Monday 16:10, up
to Thursday 20:40 to Friday 16:10. A time zone without daylight saving, such as
UTC, keeps those hours the same all year in every location.

`all_instance_ids` lists the instances Terraform owns individually, also as
`local.all_instance_ids` for files a consumer generates into this directory.

## Testing

    cd modules/aws-cluster
    tofu init -backend=false && tofu test
