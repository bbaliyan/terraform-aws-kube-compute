# aws-node-iam

This module creates the IAM role and the instance profile of an AWS node. It can also let the role read one agent token parameter.

The `aws-control-plane`, `aws-node-pool` and `aws-static-node` modules call it. Use it directly only if you build your own node module.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_agent_token"></a> [agent\_token](#input\_agent\_token) | Lets the role read one agent token parameter: the policy name and the parameter name. Null creates no policy. | <pre>object({<br/>    policy_name   = string<br/>    ssm_parameter = string<br/>  })</pre> | `null` | no |
| <a name="input_attach_ebs_csi_policy"></a> [attach\_ebs\_csi\_policy](#input\_attach\_ebs\_csi\_policy) | Attach AmazonEBSCSIDriverPolicy to the role. | `bool` | `true` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | Region of the agent token parameter. | `string` | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Name prefix of the IAM role and the instance profile. AWS caps it at 38 characters. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for the IAM role and the instance profile. | `map(string)` | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_instance_profile_name"></a> [instance\_profile\_name](#output\_instance\_profile\_name) | Name of the node instance profile. |
| <a name="output_role_name"></a> [role\_name](#output\_role\_name) | Name of the node IAM role. |
<!-- END_TF_DOCS -->
