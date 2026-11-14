# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

run "node_resources" {
  # apply (not plan): random_password's result (embedded in node-bootstrap's rendered
  # cloud-init payload) is unknown at plan time, which makes user_data_base64 unknown
  # too — matching proxmox-control-plane's own precedent for the same reason.
  command = apply
  variables {
    cluster_name          = "example"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8", "192.168.0.0/16"]
    subnet_id             = "subnet-abc"
    os_image_ami_id       = "ami-0123456789abcdef0"
  }

  assert {
    condition     = aws_instance.control_plane["0"].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced (http_tokens=required)"
  }
  assert {
    condition     = length(aws_instance.control_plane["0"].user_data_base64) > 0
    error_message = "instance must attach node-bootstrap user-data"
  }
  assert {
    condition     = aws_instance.control_plane["0"].iam_instance_profile == module.node_iam.instance_profile_name
    error_message = "instance must use the module instance profile"
  }
  assert {
    condition     = aws_instance.control_plane["0"].root_block_device[0].volume_type == "gp3"
    error_message = "root volume type must honor the default (gp3)"
  }
  assert {
    condition     = aws_instance.control_plane["0"].root_block_device[0].delete_on_termination
    error_message = "the root volume must be deleted with its instance"
  }
  assert {
    condition = contains(concat(
      [for r in aws_vpc_security_group_ingress_rule.node : r.to_port],
      [for r in aws_vpc_security_group_ingress_rule.node_extra : r.to_port]
    ), 6443)
    error_message = "SG must open the Kubernetes API port 6443 across all CIDRs"
  }
  assert {
    condition = !contains(concat(
      [for r in aws_vpc_security_group_ingress_rule.node : r.to_port],
      [for r in aws_vpc_security_group_ingress_rule.node_extra : r.to_port]
    ), 22)
    error_message = "SG must NOT open SSH (22) on any CIDR"
  }
  assert {
    condition     = length(output.node_iam_role_name) > 0
    error_message = "node_iam_role_name must expose the role of the shared IAM module"
  }
}
