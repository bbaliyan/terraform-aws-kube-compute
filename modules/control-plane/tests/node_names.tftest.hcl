# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

variables {
  cluster_name          = "7c-demo"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1c", vpc_id = "vpc-mock" }
}

run "a_cluster_name_may_start_with_a_digit_and_keeps_the_old_node_name" {
  command = plan

  assert {
    condition     = aws_instance.control_plane.tags.Name == "cp-7c-demo-1"
    error_message = "got ${aws_instance.control_plane.tags.Name}"
  }
}

run "the_template_gives_the_zone_and_number" {
  command = plan

  variables {
    node_name_template = "demo-{zone}-cp{number}"
  }

  assert {
    condition     = aws_instance.control_plane.tags.Name == "demo-c-cp01"
    error_message = "got ${aws_instance.control_plane.tags.Name}"
  }
  assert {
    condition     = aws_instance.control_plane.root_block_device[0].tags.Name == "demo-c-cp01-root"
    error_message = "got ${aws_instance.control_plane.root_block_device[0].tags.Name}"
  }
}

run "each_ha_node_gets_its_own_zone_and_number" {
  command = plan

  variables {
    node_name_template  = "demo-{zone}-cp{number}"
    control_plane_count = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
  }

  assert {
    condition     = aws_instance.control_plane.tags.Name == "demo-a-cp01"
    error_message = "got ${aws_instance.control_plane.tags.Name}"
  }
  assert {
    condition     = aws_instance.control_plane_additional["1"].tags.Name == "demo-b-cp02"
    error_message = "got ${aws_instance.control_plane_additional["1"].tags.Name}"
  }
  assert {
    condition     = aws_instance.control_plane_additional["2"].tags.Name == "demo-c-cp03"
    error_message = "got ${aws_instance.control_plane_additional["2"].tags.Name}"
  }
}

run "boot_scripts_make_the_user_data_bigger" {
  command = apply

  variables {
    node_name_template = "demo-{zone}-cp{number}"
    boot_scripts       = ["echo \"joining as $NODE_NAME\" > /var/log/boot-script.log"]
  }

  assert {
    condition     = length(aws_instance.control_plane.user_data_base64) > 0
    error_message = "the node must still get its user data"
  }
}

run "a_template_without_number_is_refused" {
  command = plan

  variables {
    node_name_template = "demo-{zone}-cp"
  }

  expect_failures = [var.node_name_template]
}

run "a_template_with_capitals_is_refused" {
  command = plan

  variables {
    node_name_template = "DEMO-{zone}-cp{number}"
  }

  expect_failures = [var.node_name_template]
}

run "a_template_starting_with_a_hyphen_is_refused" {
  command = plan

  variables {
    node_name_template = "-{number}"
  }

  expect_failures = [var.node_name_template]
}

run "a_misspelled_placeholder_is_refused" {
  command = plan

  variables {
    node_name_template = "demo-{zon}-cp{number}"
  }

  expect_failures = [var.node_name_template]
}

run "a_boot_script_with_the_end_marker_is_refused" {
  command = plan

  variables {
    boot_scripts = ["echo one\nKUBE_COMPUTE_BOOT_SCRIPT\necho two"]
  }

  expect_failures = [var.boot_scripts]
}
