# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
}

run "single_control_plane_default" {
  command = plan
  variables {
    instance_type = "m7g.large"
  }
  assert {
    condition     = aws_instance.control_plane.instance_type == "m7g.large"
    error_message = "control_plane_count=1 (default) must plan exactly one control-plane instance"
  }
}

run "control_plane_count_rejects_2" {
  command = plan
  variables {
    control_plane_count = 2
  }
  expect_failures = [var.control_plane_count]
}

run "control_plane_count_rejects_4" {
  command = plan
  variables {
    control_plane_count = 4
  }
  expect_failures = [var.control_plane_count]
}

run "cluster_type_rejects_invalid" {
  command = plan
  variables {
    cluster_type = "solo"
  }
  expect_failures = [var.cluster_type]
}

run "dedicated_control_plane_still_plans_one_node" {
  command = plan
  variables {
    cluster_type = "dedicated_control_plane"
  }
  assert {
    condition     = aws_instance.control_plane.instance_type != ""
    error_message = "dedicated_control_plane must still plan the single control-plane node (taint content is asserted in node-bootstrap's own render tests)"
  }
}

run "control_plane_subnets_required_above_one" {
  command = plan
  variables {
    control_plane_count = 3
    # control_plane_subnets omitted on purpose
  }
  expect_failures = [var.control_plane_subnets]
}
