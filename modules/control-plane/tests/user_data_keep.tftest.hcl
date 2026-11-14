# SPDX-License-Identifier: Apache-2.0
# A changed user data does not replace a running control-plane node. The runs
# share one state and run in order. Every run is an apply, because the payload
# carries a generated token and is unknown at plan.
#
# How a run tells a kept node from a replaced one: the instance ignores changes
# to user_data_base64, so a kept node keeps the user data it was created with.
# connectivity_user_data_base64 is the new render for the first node.
#
# What a mock cannot show:
# - The mock gives an instance the same id each time it creates one, so an id
#   does not show a replacement.
# - The real EC2 API is not called, so these runs do not prove that AWS keeps
#   the node running, or what cloud-init does on a replaced node.
# They show what OpenTofu stores for the module's own resources.
mock_provider "aws" {}

variables {
  os_image_ami_id       = "ami-0123456789abcdef0"
  cluster_name          = "example"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  platform_extra_helm_parameters = {
    "global.example" = "one"
  }
}

run "create" {
  command = apply

  assert {
    condition     = aws_instance.control_plane["0"].user_data_base64 == output.connectivity_user_data_base64
    error_message = "a new node must boot with the current user data"
  }
}

run "keeps_the_node_when_a_helm_parameter_changes" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "two"
    }
  }

  assert {
    condition     = aws_instance.control_plane["0"].user_data_base64 != output.connectivity_user_data_base64
    error_message = "a user data change must not replace the control-plane node"
  }
}
