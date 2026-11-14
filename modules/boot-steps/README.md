# aws-boot-steps

Renders the boot steps that only an AWS node needs. It produces text and creates no resource.

Pass the `steps` output to the `provider_steps` input of `node-bootstrap`.

## Steps

- `ssm-agent` always runs. It starts SSM Agent, which is the operator's access path to the node.
- `aws-provider-id` runs when `aws_provider_id` is true. It reads the zone, the instance ID and the instance type from EC2 metadata. It then writes an RKE2 `config.yaml.d` drop-in. The drop-in sets the node providerID and the `node.kubernetes.io/instance-type` label.

cluster-autoscaler and the AWS cloud controller manager find the instance of a node by its providerID. Every role takes the label, control plane included.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_provider_id"></a> [aws\_provider\_id](#input\_aws\_provider\_id) | Registers the node with providerID aws:///<zone>/<instance-id> and the label node.kubernetes.io/instance-type, both read from EC2 metadata before RKE2 starts. cluster-autoscaler and the AWS cloud controller manager find the instance by providerID. | `bool` | `false` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_steps"></a> [steps](#output\_steps) | Value for node-bootstrap's provider\_steps: a list of { name, commands } objects, one per enabled step. |
<!-- END_TF_DOCS -->
