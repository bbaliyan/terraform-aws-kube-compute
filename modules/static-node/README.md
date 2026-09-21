# aws-static-node

A group of **named** worker instances joining an existing `aws-control-plane`
cluster. One module call is one role: `platform`, `dedicated`, `build`. Set
`node_count` for more than one machine in that role.

```hcl
module "platform_nodes" {
  source = "../aws-static-node"

  cluster_name              = "cluster-x"
  group_name                = "platform"
  aws_region                = "eu-west-1"
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  security_group_ids        = [module.control_plane.cluster_security_group_id, module.control_plane.node_security_group_id]
  subnet_id                 = module.control_plane.subnet_id

  instance_type = "t4g.large"
  node_labels   = { "workload" = "platform" }
}
```

## Why this exists next to aws-node-pool

`aws-node-pool` creates an autoscaling group that cluster-autoscaler scales from
zero. Capacity a cluster must always have — the platform, above all — belongs
here instead, for three reasons.

**A stop schedule cannot target a group member.** These are development clusters
that stop every evening. An autoscaling group's health check treats an instance
that is not in the running state as failed and replaces it, so an
`ec2:StopInstances` call against a member is undone within minutes. The
sanctioned way to stop a group is Standby or a desired capacity of zero: a
different API call, a different IAM action, and a different thing to reverse the
next morning. Named instances take the same one-line schedule the control-plane
node already has.

**Per-instance IAM and SSM need a stable id.** The stop schedule's own IAM
policy is written against instance ARNs so it cannot stop anything else in the
account. A group hands out a new instance id on every replacement, which would
mean either re-scoping the policy on every apply or widening it to the whole
region.

**Each node needs a hostname Terraform chose.** RKE2 registers the Kubernetes
node name from the OS hostname. Every member of a group shares one launch
template and therefore one rendered cloud-init, which is why `aws-node-pool`
must pass `set_hostname = false` and let cloud-init's EC2 datasource invent a
name. Here each node has its own render, so `bharat-dedicated-1` is the name
that shows up in `kubectl get nodes`.

What is given up: nothing reacts to load, and nothing replaces a failed node.
Elastic capacity is `aws-node-pool`'s job.

## Availability zone

Pass `module.control_plane.subnet_id` for `subnet_id` unless there is a
deliberate reason not to. That puts every node in the control plane's own zone,
which matters because an EBS volume cannot cross zones: a worker in the wrong
one cannot mount the data it was created for. Cross-zone traffic is also billed
in both directions. Latency is not the reason — inside a region it is low
single-digit milliseconds and multi-zone clusters are routine.

Doing it this way rather than restricting the cluster to a single subnet keeps
`aws-control-plane`'s ordered `subnet_names` search intact, so the cluster can
still fall through to a second subnet when the first runs out of addresses.

## Labels and taints

The module always sets two labels: `topology.kubernetes.io/zone` from the subnet
and `kube-compute.io/node-group` from `group_name`. A workload selects the group
by the latter without the caller having to pass a label duplicating the name it
already gave.

Labels alone make a dedicated node **preferred**, not dedicated. A `nodeSelector`
pins the workload you named to this group, but nothing keeps anything else off
it. `node_taints` is the half that does, and it needs a matching toleration on
the workload or nothing schedules there at all.

## Security groups

`security_group_ids` needs the control plane's `cluster_security_group_id` at
minimum, or the node cannot reach the control plane to join. Add
`node_security_group_id` for a group that will run the ingress controller:
external traffic on the cluster's `ingress_ports` arrives at whichever node the
ingress pods sit on, so moving them off the control plane without moving that
rule leaves the ports answering nowhere.

## IAM

One role per group, not per node — every node in a group reads the same SSM
parameter and needs the same managed policies. The role gets
`AmazonSSMManagedInstanceCore` (SSM is the only operator access path in this
project; there is no inbound SSH), an inline policy scoped to exactly the one
agent-token SSM parameter, and `AmazonEBSCSIDriverPolicy`.

The EBS CSI policy defaults **on** deliberately. The CSI controller makes the
`CreateVolume`/`AttachVolume` calls and is an ordinary Deployment the scheduler
can place on any node that tolerates its taints, so a group without the policy
breaks volume provisioning silently whenever the controller happens to land
there. Turn it off only for a group you have kept the controller off by taint.

## Mixed architectures in one cluster

`instance_type` decides the architecture. The module reads
`supported_architectures` from AWS's own instance-type metadata and filters the
AMI lookup on it, so an arm64 platform node and an x86_64 dedicated-workload node can
share one `os_image_name` value as long as its architecture segment is a
wildcard. Without that filter, a wildcard would let either build satisfy either
node.
