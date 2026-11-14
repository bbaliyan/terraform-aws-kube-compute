# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["x86_64"] }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0", root_device_name = "/dev/sda1" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

override_data {
  target = data.aws_ec2_instance_type.selected["t4g.large"]
  values = { supported_architectures = ["arm64"] }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id           = "ami-0123456789abcdef0"
  cluster_name              = "example"
  group_name                = "workers"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/example/agent-token"
  cluster_security_group_id = "sg-cluster123"
  subnet_id                 = "subnet-worker-a"
  instance_type_max_sizes   = { "t4g.large" = 2 }
}

run "an_arm64_instance_type_reports_arm64" {
  command = plan

  assert {
    condition     = output.autoscaling_groups["t4g.large"].node_arch == "arm64"
    error_message = "a Graviton instance type must report arm64"
  }
}

run "an_x86_64_instance_type_reports_x86_64" {
  command = plan

  variables {
    instance_type_max_sizes = { "t4g.large" = 2, "m7i.large" = 1 }
  }

  assert {
    condition     = output.autoscaling_groups["m7i.large"].node_arch == "x86_64" && output.autoscaling_groups["t4g.large"].node_arch == "arm64"
    error_message = "each instance type must report the architecture its own type supports"
  }
}

run "an_x86_64_type_looks_up_an_x86_64_image_by_name" {
  command = plan

  variables {
    os_image_ami_id         = null
    os_image_name           = "almalinux10-*-kube-image-*"
    instance_type_max_sizes = { "t4g.large" = 2, "m7i.large" = 1 }
  }

  assert {
    condition     = [for f in data.aws_ami.by_name["m7i.large"].filter : f.values if f.name == "architecture"][0] == toset(["x86_64"])
    error_message = "an x86_64 type must look up an x86_64 image"
  }
}

run "an_arm64_type_looks_up_an_arm64_image_by_name" {
  command = plan

  variables {
    os_image_ami_id = null
    os_image_name   = "almalinux10-*-kube-image-*"
  }

  assert {
    condition     = [for f in data.aws_ami.by_name["t4g.large"].filter : f.values if f.name == "architecture"][0] == toset(["arm64"])
    error_message = "the name lookup must filter on the instance type's architecture"
  }
}

run "an_explicit_ami_id_skips_the_name_lookup" {
  command = plan

  variables {
    os_image_name = "almalinux10-*-kube-image-*"
  }

  assert {
    condition     = length(data.aws_ami.by_name) == 0
    error_message = "os_image_ami_id must take precedence over os_image_name"
  }
}
