# aws-node-pool

One role of RKE2 worker nodes that cluster-autoscaler scales from zero, joining an
existing `aws-control-plane` cluster. `aws-cluster` creates one per
`autoscaled_nodes` entry and derives each maximum from the role's `max_cpu_cores`
and `max_memory_gib`.

```hcl
module "workers" {
  source = "../aws-node-pool"

  cluster_name              = "cluster-x"
  group_name                = "workers"
  aws_region                = "eu-west-1"
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_security_group_id = module.control_plane.cluster_security_group_id
  subnet_id                 = module.control_plane.subnet_id

  instance_type_max_sizes = { "m7a.large" = 8, "m7a.xlarge" = 4 }
}
```

## One Auto Scaling group per instance type

cluster-autoscaler simulates every new node of a group as the same shape, so a
group mixing sizes would be sized wrongly. Each instance type is therefore its own
group, from zero to its maximum, and all of them share the role's IAM role, labels
and taints.

- **Discovery.** Each group is tagged `k8s.io/cluster-autoscaler/enabled` and
  `k8s.io/cluster-autoscaler/<cluster_name>`.
- **Scale from zero.** With no nodes to inspect, the autoscaler reads the
  instance type from the launch template, and the labels and taints from
  `k8s.io/cluster-autoscaler/node-template/*` tags.
- **Matching nodes to instances.** Every node registers
  `aws:///<zone>/<instance-id>` as its providerID.
- **Desired capacity.** The autoscaler owns it, so Terraform never sets it.

The autoscaler terminates instances but does not delete their Node objects.
kube-platform's AWS cloud controller manager does, which is what lets a pod bound
to a vanished node, and its volume, move.

## Nodes

Every node of a role carries `kube-compute.io/node-group=<group_name>`,
`topology.kubernetes.io/zone` and `node.kubernetes.io/instance-type`. EC2 names
the host. `node_taints` keeps other pods off the role; pods that belong there need
a matching toleration.

The role has one IAM role with SSM access, the EBS CSI driver policy, and read
access to the one agent-token parameter. Nodes take only the cluster's east-west
security group; ingress runs on the platform node.

Pass the control plane's `subnet_id`: an EBS volume cannot cross availability
zones.

## Testing

    cd modules/aws-node-pool
    tofu init -backend=false && tofu test
