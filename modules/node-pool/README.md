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
- **Scale from zero.** With no nodes to inspect, the autoscaler reads the instance type
  from the launch template. It reads the labels and taints from
  `k8s.io/cluster-autoscaler/node-template/*` tags.
- **Matching nodes to instances.** Every node registers `aws:///<zone>/<instance-id>` as
  its providerID.
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

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_agent_token_ssm_parameter"></a> [agent\_token\_ssm\_parameter](#input\_agent\_token\_ssm\_parameter) | The control plane's agent\_token\_ssm\_parameter output. The group's IAM role can read only this parameter. | `string` | n/a | yes |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region the group runs in. Must match the control plane's region. | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity this group joins. Must match the control plane's cluster\_name. | `string` | n/a | yes |
| <a name="input_cluster_security_group_id"></a> [cluster\_security\_group\_id](#input\_cluster\_security\_group\_id) | The control plane's cluster\_security\_group\_id output, for east-west traffic. Nodes in this group take no external traffic. | `string` | n/a | yes |
| <a name="input_destroy_after"></a> [destroy\_after](#input\_destroy\_after) | Something that must outlive this module's nodes at destroy. It orders their destruction and nothing else, so it is never read as a value. | `string` | `null` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Upstream DNS resolver IPs for a search-domain-free kubelet resolv-conf. Pass the same value the control plane got. | `list(string)` | `null` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional tags applied to every resource this module creates and every instance the groups launch. | `map(string)` | `{}` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_group_name"></a> [group\_name](#input\_group\_name) | Names the role these nodes play, e.g. "workers". Every node carries it as the kube-compute.io/node-group label, whatever its instance type. | `string` | n/a | yes |
| <a name="input_instance_type_max_sizes"></a> [instance\_type\_max\_sizes](#input\_instance\_type\_max\_sizes) | Instance types this role launches, each with the most instances of that type cluster-autoscaler may run. Each type is its own Auto Scaling group, starting at zero: cluster-autoscaler requires every instance in a group to have the same shape. | `map(number)` | n/a | yes |
| <a name="input_node_labels"></a> [node\_labels](#input\_node\_labels) | Node labels beyond the zone, instance-type and node-group labels this module always sets. | `map(string)` | `{}` | no |
| <a name="input_node_taints"></a> [node\_taints](#input\_node\_taints) | Node taints, each "key=value:Effect". A pod needs a matching toleration to land here. | `list(string)` | `[]` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Installs OS updates daily with dnf-automatic, without rebooting. See node-bootstrap's own variable. | `bool` | `true` | no |
| <a name="input_os_image_ami_id"></a> [os\_image\_ami\_id](#input\_os\_image\_ami\_id) | AMI ID of a kube-images build for every instance type. Set this or os\_image\_name. | `string` | `null` | no |
| <a name="input_os_image_name"></a> [os\_image\_name](#input\_os\_image\_name) | AMI name, e.g. kube-images' build name, resolved against this account's own AMIs for each instance type's architecture. Accepts EC2 Name-filter wildcards. Ignored when os\_image\_ami\_id is set. | `string` | `null` | no |
| <a name="input_registration_address"></a> [registration\_address](#input\_registration\_address) | The control plane's registration\_address output. Nodes join via https://<this>:9345. | `string` | n/a | yes |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror. Null = pull from upstream. | `string` | `null` | no |
| <a name="input_root_volume_size_gb"></a> [root\_volume\_size\_gb](#input\_root\_volume\_size\_gb) | Root EBS volume size (GB). | `number` | `20` | no |
| <a name="input_root_volume_type"></a> [root\_volume\_type](#input\_root\_volume\_type) | Root EBS volume type (gp3, gp2, io2, ...). | `string` | `"gp3"` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet the group launches into. Pass the control plane's subnet\_id output: an EBS volume cannot cross availability zones, so a node in another zone cannot mount the data it was created for. | `string` | n/a | yes |
| <a name="input_trusted_ca_in_image"></a> [trusted\_ca\_in\_image](#input\_trusted\_ca\_in\_image) | Whether the node image already carries trusted\_ca\_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt, so it stays out of user data. | `bool` | `false` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) added to each node's OS trust store. Null = none. Sensitive. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_autoscaling_groups"></a> [autoscaling\_groups](#output\_autoscaling\_groups) | Map of instance type -> {name, arn, max\_size, node\_arch}, one Auto Scaling group per type. Their instances are invisible to Terraform; find them through the group. |
| <a name="output_availability_zone"></a> [availability\_zone](#output\_availability\_zone) | Availability zone of subnet\_id. |
| <a name="output_node_iam_role_name"></a> [node\_iam\_role\_name](#output\_node\_iam\_role\_name) | IAM role attached to every node of this role. |
| <a name="output_node_labels"></a> [node\_labels](#output\_node\_labels) | Labels every node of this role carries. Each node also carries node.kubernetes.io/instance-type. |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM). |
| <a name="output_node_taints"></a> [node\_taints](#output\_node\_taints) | Taints every node of this role carries. |
| <a name="output_subnet_id"></a> [subnet\_id](#output\_subnet\_id) | Subnet every group launches into. |
<!-- END_TF_DOCS -->

## Testing

    cd modules/aws-node-pool
    tofu init -backend=false && tofu test
