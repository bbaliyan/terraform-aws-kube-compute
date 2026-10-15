# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  cluster_name              = "7c-demo"
  group_name                = "platform"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/7c-demo/agent-token"
  security_group_ids        = ["sg-cluster123"]
  subnet_id                 = "subnet-cp-a"
  node_count                = 2
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1b", vpc_id = "vpc-mock" }
}

run "without_a_template_the_names_stay_as_they_were" {
  command = plan

  assert {
    condition     = aws_instance.node["2"].tags.Name == "platform-7c-demo-2"
    error_message = "got ${aws_instance.node["2"].tags.Name}"
  }
}

run "the_template_gives_the_zone_and_number" {
  command = plan

  variables {
    node_name_template = "demo-{zone}-wk{number}"
  }

  assert {
    condition     = aws_instance.node["1"].tags.Name == "demo-b-wk01" && aws_instance.node["2"].tags.Name == "demo-b-wk02"
    error_message = "got ${aws_instance.node["1"].tags.Name} and ${aws_instance.node["2"].tags.Name}"
  }
}

run "boot_scripts_plan" {
  command = plan

  variables {
    node_name_template = "demo-{zone}-wk{number}"
    boot_scripts       = ["echo first", "echo second"]
  }

  assert {
    condition     = length(aws_instance.node) == 2
    error_message = "boot scripts must not change how many nodes there are"
  }
}

run "a_template_without_number_is_refused" {
  command = plan

  variables {
    node_name_template = "demo-{zone}-wk"
  }

  expect_failures = [var.node_name_template]
}
