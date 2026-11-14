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
  instance_type_max_sizes   = { "t3a.large" = 3 }
}

run "an_empty_taint_list_renders_no_taint_tag" {
  command = plan

  assert {
    condition     = alltrue([for g in aws_autoscaling_group.node : length([for t in g.tag : t.key if strcontains(t.key, "/taint/")]) == 0])
    error_message = "a group with no taints must advertise none"
  }
  assert {
    condition     = length(output.node_taints) == 0
    error_message = "node_taints output must be empty when none are set"
  }
}

run "several_taints_each_get_a_tag" {
  command = plan

  variables {
    node_taints = ["gpu=true:NoSchedule", "team=a:NoExecute"]
  }

  assert {
    condition = alltrue([
      for key, value in {
        "k8s.io/cluster-autoscaler/node-template/taint/gpu"  = "true:NoSchedule"
        "k8s.io/cluster-autoscaler/node-template/taint/team" = "a:NoExecute"
      } : contains([for t in aws_autoscaling_group.node["t3a.large"].tag : t.value if t.key == key], value)
    ])
    error_message = "every taint must be advertised with its effect"
  }
}

run "a_taint_value_with_an_equals_sign_is_rejected" {
  command = plan

  variables {
    node_taints = ["key=a=b:NoSchedule"]
  }

  expect_failures = [var.node_taints]
}

run "a_taint_with_an_unknown_effect_is_rejected" {
  command = plan

  variables {
    node_taints = ["key=value:Sometimes"]
  }

  expect_failures = [var.node_taints]
}

run "an_empty_taint_value_is_accepted" {
  command = plan

  variables {
    node_taints = ["dedicated=:NoSchedule"]
  }

  assert {
    condition     = contains([for t in aws_autoscaling_group.node["t3a.large"].tag : t.value if t.key == "k8s.io/cluster-autoscaler/node-template/taint/dedicated"], ":NoSchedule")
    error_message = "a taint with an empty value must still be advertised"
  }
}

run "caller_labels_are_advertised_next_to_the_built_in_ones" {
  command = plan

  variables {
    node_labels = { tier = "batch" }
  }

  assert {
    condition     = contains([for t in aws_autoscaling_group.node["t3a.large"].tag : t.value if t.key == "k8s.io/cluster-autoscaler/node-template/label/tier"], "batch")
    error_message = "a caller label must be advertised to cluster-autoscaler"
  }
  assert {
    condition     = output.node_labels["kube-compute.io/node-group"] == "workers" && output.node_labels["tier"] == "batch"
    error_message = "the group label must stay and the caller label must be added"
  }
}

run "extra_tags_reach_every_launch_template_and_launched_instance" {
  command = plan

  variables {
    extra_tags = { Team = "platform" }
  }

  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.tags.Team == "platform" && lt.tags.ManagedBy == "kube-compute"])
    error_message = "extra tags must be added to the built-in tags on every launch template"
  }
  assert {
    condition     = contains([for t in aws_autoscaling_group.node["t3a.large"].tag : t.key if t.propagate_at_launch], "Team")
    error_message = "extra tags must propagate to launched instances"
  }
}

run "the_longest_valid_names_keep_the_iam_prefix_within_38_characters" {
  command = plan

  variables {
    cluster_name = "cluster-abcdefghijklmnopqrstuvw"
    group_name   = "group-abcdefghijklmno"
  }

  assert {
    condition     = local.iam_name_prefix == "kube-compute-cluster-abcdefghijklmnopq"
    error_message = "the longest cluster and group names must give an IAM name_prefix cut at exactly 38 characters"
  }
}

run "a_group_name_of_22_characters_is_rejected" {
  command = plan

  variables {
    group_name = "group-abcdefghijklmnop"
  }

  expect_failures = [var.group_name]
}

run "the_agent_token_is_fetched_with_the_group_region_and_parameter" {
  command = plan

  assert {
    condition     = strcontains(local.agent_token_fetch_command, "--name '/kube-compute/example/agent-token'") && strcontains(local.agent_token_fetch_command, "--region eu-west-1")
    error_message = "the node must fetch its own parameter from the group's region"
  }
}
