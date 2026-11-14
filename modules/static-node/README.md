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

**A stop schedule cannot target a group member.** An autoscaling group's health check treats an instance that is not in the running state as failed and replaces it. So an `ec2:StopInstances` call against a member is undone within minutes. The sanctioned way to stop a group is Standby or a desired capacity of zero. That is a different API call, a different IAM action, and a different thing to reverse the next morning. Named instances take the same one-line schedule the control-plane
node already has.

**Per-instance IAM and SSM need a stable id.** The stop schedule's own IAM policy is
written against instance ARNs. So it cannot stop anything else in the account. A group
hands out a new instance id on every replacement. That would mean either re-scoping the
policy on every apply or widening it to the whole region.

**Each node needs a hostname Terraform chose.** RKE2 registers the Kubernetes node name
from the OS hostname. Every member of a group shares one launch template and therefore one
rendered cloud-init. That is why `aws-node-pool` must pass `set_hostname = false` and let
cloud-init's EC2 datasource invent a name. Here each node has its own render, so
`example-dedicated-1` is the name that shows up in `kubectl get nodes`.

What is given up: nothing reacts to load, and nothing replaces a failed node.
Elastic capacity is `aws-node-pool`'s job.

## Availability zone

Pass `module.control_plane.subnet_id` for `subnet_id` unless there is a deliberate reason
not to. That puts every node in the control plane's own zone. This matters because an EBS
volume cannot cross zones. A worker in the wrong zone cannot mount the data it was created
for. Cross-zone traffic is also billed in both directions. Latency is not the reason —
inside a region it is low single-digit milliseconds and multi-zone clusters are routine.

Doing it this way, rather than restricting the cluster to a single subnet, keeps
`aws-control-plane`'s ordered `subnet_names` search intact. So a new cluster can still
fall through to a second subnet when the first lacks room for it. Once placed, the cluster
stays in that subnet for good.

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

`security_group_ids` needs the control plane's `cluster_security_group_id` at minimum, or
the node cannot reach the control plane to join. Add `node_security_group_id` for a group
that will run the ingress controller. External traffic on the cluster's `ingress_ports`
arrives at whichever node the ingress pods sit on. Moving them off the control plane
without moving that rule leaves the ports answering nowhere.

## IAM

One role per group, not per node — every node in a group reads the same SSM parameter
and needs the same managed policies. The role gets `AmazonSSMManagedInstanceCore`, an
inline policy scoped to exactly the one agent-token SSM parameter, and
`AmazonEBSCSIDriverPolicy`. SSM is the only operator access path in this project; there is
no inbound SSH.

The EBS CSI policy defaults **on** deliberately. The CSI controller makes the
`CreateVolume`/`AttachVolume` calls. It is an ordinary Deployment the scheduler can place
on any node that tolerates its taints. So a group without the policy breaks volume
provisioning silently whenever the controller happens to land there. Turn it off only for
a group you have kept the controller off by taint.

## Mixed architectures in one cluster

`instance_type` decides the architecture. The module reads `supported_architectures` from
AWS's own instance-type metadata and filters the AMI lookup on it. So an arm64 platform
node and an x86_64 dedicated-workload node can share one `os_image_name` value, as long as
its architecture segment is a wildcard. Without that filter, a wildcard would let either
build satisfy either node.

## A change to the user data of a running node

A change to any input in the user data, such as `node_labels`, does not touch a
running node. The instance keeps the user data it booted with. To apply the change,
replace the node on purpose.

1. If the node runs workloads that must not stop, drain it: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
2. Delete the Kubernetes node: `kubectl delete node <node>`.
3. Replace the instance: `tofu apply -replace='module.<name>.aws_instance.node["1"]'`.
4. Verify that the node is `Ready`: `kubectl get nodes`.

Inside `aws-cluster`, the address is
`module.<name>.module.static_nodes["<group>"].aws_instance.node["1"]`.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_agent_token_ssm_parameter"></a> [agent\_token\_ssm\_parameter](#input\_agent\_token\_ssm\_parameter) | This cluster's aws-control-plane agent\_token\_ssm\_parameter output. This module's IAM role is scoped to read only it. | `string` | n/a | yes |
| <a name="input_attach_ebs_csi_policy"></a> [attach\_ebs\_csi\_policy](#input\_attach\_ebs\_csi\_policy) | Attach AmazonEBSCSIDriverPolicy to this group's IAM role. On by default, because the EBS CSI controller can run on any node that tolerates its taints. Set false only for a group that the controller is kept off by taint. | `bool` | `true` | no |
| <a name="input_aws_provider_id"></a> [aws\_provider\_id](#input\_aws\_provider\_id) | Registers every node with providerID aws:///<zone>/<instance-id>. Needed on every node of a cluster whose nodes cluster-autoscaler and the AWS cloud controller manager look up by instance. Changing it replaces the nodes. | `bool` | `false` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region these nodes run in. Must match the control plane's region. | `string` | n/a | yes |
| <a name="input_cluster_fqdn_suffix"></a> [cluster\_fqdn\_suffix](#input\_cluster\_fqdn\_suffix) | The control plane's fqdn\_suffix, used only to give each node a matching cloud-init fqdn. Never the API server name. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity these nodes join. Must match the control plane's cluster\_name. | `string` | n/a | yes |
| <a name="input_destroy_after"></a> [destroy\_after](#input\_destroy\_after) | Something that must outlive this module's nodes at destroy. It orders their destruction and nothing else, so it is never read as a value. | `string` | `null` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | Upstream DNS resolver IPs, passed to node-bootstrap for a search-domain-free kubelet resolv-conf. Pass the same value the control plane got: a wildcard cluster DNS record poisons every node's pods identically. | `list(string)` | `null` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional tags applied to every resource this module creates. | `map(string)` | `{}` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_group_name"></a> [group\_name](#input\_group\_name) | Names a role, not a machine: "platform", "dedicated", "build". Used in each instance and Kubernetes node name (<cluster\_name>-<group\_name>-<n>), the IAM role, and the automatic kube-compute.io/node-group label. | `string` | n/a | yes |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type for every node. CPU architecture is derived from AWS's own instance-type metadata, so an arm64 type resolves an arm64 image with no second input. | `string` | `"m7g.medium"` | no |
| <a name="input_node_count"></a> [node\_count](#input\_node\_count) | How many named instances this group has. | `number` | `1` | no |
| <a name="input_node_labels"></a> [node\_labels](#input\_node\_labels) | Additional node-label: entries beyond the AZ and node-group labels this module always sets. Labels are what a workload selects a node by; keeping others off it is node\_taints' job. | `map(string)` | `{}` | no |
| <a name="input_node_name_template"></a> [node\_name\_template](#input\_node\_name\_template) | Name for each node of the group: its hostname, Kubernetes node name and Name tag. {zone} becomes the last letter of the node's availability zone, and {number} the node's number as two digits (01, 02, ...). Null keeps <group\_name>-<cluster\_name>-<n>. | `string` | `null` | no |
| <a name="input_node_taints"></a> [node\_taints](#input\_node\_taints) | node-taint: entries, each a full "key=value:Effect" string. Needs a matching toleration on the workload that belongs here, or nothing schedules at all. | `list(string)` | `[]` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Installs OS updates daily with dnf-automatic, without rebooting. See node-bootstrap's own variable. | `bool` | `true` | no |
| <a name="input_os_image_ami_id"></a> [os\_image\_ami\_id](#input\_os\_image\_ami\_id) | AMI ID of a kube-images build. Set this or os\_image\_name. | `string` | `null` | no |
| <a name="input_os_image_name"></a> [os\_image\_name](#input\_os\_image\_name) | AMI name, e.g. kube-images' build name. Resolved against this account's own AMIs and the derived architecture. Accepts EC2 Name-filter wildcards, so one pattern with a wildcard architecture segment serves both architectures. Ignored when os\_image\_ami\_id is set. | `string` | `null` | no |
| <a name="input_registration_address"></a> [registration\_address](#input\_registration\_address) | The control plane's registration\_address output. Nodes join via https://<this>:9345. | `string` | n/a | yes |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror. Null = pull from upstream. | `string` | `null` | no |
| <a name="input_root_volume_size_gb"></a> [root\_volume\_size\_gb](#input\_root\_volume\_size\_gb) | Root EBS volume size (GB). | `number` | `20` | no |
| <a name="input_root_volume_type"></a> [root\_volume\_type](#input\_root\_volume\_type) | Root EBS volume type (gp3, gp2, io2, ...). | `string` | `"gp3"` | no |
| <a name="input_security_group_ids"></a> [security\_group\_ids](#input\_security\_group\_ids) | Security groups attached to every node. The control plane's cluster\_security\_group\_id at minimum; add its node\_security\_group\_id for the group that runs the ingress controller, or the cluster's external ports keep answering on a node no longer serving them. | `list(string)` | n/a | yes |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet every node launches into. Pass the control plane's own subnet\_id output unless there is a deliberate reason not to: an EBS volume cannot cross availability zones, so a worker in another one cannot mount the data it was created for. This module never creates network fabric. | `string` | n/a | yes |
| <a name="input_trusted_ca_in_image"></a> [trusted\_ca\_in\_image](#input\_trusted\_ca\_in\_image) | Whether the node image already carries trusted\_ca\_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. If true, user data omits the PEM, but the value is still used for the containerd TLS pin. The boot program fails if the file is missing. | `bool` | `false` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) added to each node's OS trust store. Null = none. Sensitive. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_availability_zone"></a> [availability\_zone](#output\_availability\_zone) | Availability zone this group is pinned to, derived from subnet\_id. |
| <a name="output_effective_ami_id"></a> [effective\_ami\_id](#output\_effective\_ami\_id) | AMI ID actually used. |
| <a name="output_instance_ids"></a> [instance\_ids](#output\_instance\_ids) | This group's EC2 instance ids. A stop schedule scopes its IAM policy to instance ARNs, so it needs ids that survive a reboot. |
| <a name="output_node_arch"></a> [node\_arch](#output\_node\_arch) | CPU architecture AWS reports for instance\_type, and what the AMI lookup filtered on. |
| <a name="output_node_iam_role_name"></a> [node\_iam\_role\_name](#output\_node\_iam\_role\_name) | IAM role name attached to every node in this group. Reference it to attach additional policies. |
| <a name="output_node_labels"></a> [node\_labels](#output\_node\_labels) | Every label applied at rke2 install time, including the two this module sets itself. Exposed so a consumer builds a nodeSelector from it rather than restating it. |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM). |
| <a name="output_node_refs"></a> [node\_refs](#output\_node\_refs) | Map of Kubernetes node name -> {instance\_id, provider}. Same shape as aws-control-plane's control\_plane\_node\_refs, so anything already targeting control-plane nodes takes workers without a second code path. An ASG cannot produce this. |
| <a name="output_node_taints"></a> [node\_taints](#output\_node\_taints) | The taints applied at rke2 install time. Exposed so a consumer builds tolerations from them rather than restating them. |
| <a name="output_private_ips"></a> [private\_ips](#output\_private\_ips) | Map of Kubernetes node name -> private IP. |
| <a name="output_subnet_id"></a> [subnet\_id](#output\_subnet\_id) | Subnet every node launched into. Exposed so a composing module can assert the group inherited the control plane's subnet rather than drifting into another zone. |
<!-- END_TF_DOCS -->
