# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["x86_64"] }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0", root_device_name = "/dev/sda1" }
  }
  # The Auto Scaling group validates the launch template id's lt- shape.
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  cluster_name              = "bharat"
  group_name                = "workers"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
  cluster_security_group_id = "sg-cluster123"
  subnet_id                 = "subnet-worker-a"
  instance_type_max_sizes   = { "t3a.large" = 3, "t3a.xlarge" = 1 }
}

run "each_instance_type_is_its_own_group_scaling_from_zero" {
  command = plan

  assert {
    condition = (
      aws_autoscaling_group.node["t3a.large"].min_size == 0 && aws_autoscaling_group.node["t3a.large"].max_size == 3 &&
      aws_autoscaling_group.node["t3a.xlarge"].min_size == 0 && aws_autoscaling_group.node["t3a.xlarge"].max_size == 1
    )
    error_message = "every instance type must be a group of its own, from zero to its max size -- cluster-autoscaler requires one shape per group"
  }
  assert {
    condition     = aws_launch_template.node["t3a.xlarge"].instance_type == "t3a.xlarge"
    error_message = "a group's launch template must launch its own instance type"
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.block_device_mappings[0].device_name == "/dev/sda1"])
    error_message = "the root volume must be mapped to the image's own root device, or AWS attaches it as a second disk and the root keeps the image's size"
  }
  assert {
    condition     = alltrue([for g in aws_autoscaling_group.node : g.vpc_zone_identifier == toset(["subnet-worker-a"])])
    error_message = "every group must launch only into the role's subnet, keeping the cluster in one availability zone"
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.vpc_security_group_ids == toset(["sg-cluster123"])])
    error_message = "a node must carry only the cluster's east-west security group"
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.metadata_options[0].http_tokens == "required" && lt.metadata_options[0].http_put_response_hop_limit == 3])
    error_message = "IMDSv2 must be enforced with a hop limit pods can reach it through"
  }
}

run "cluster_autoscaler_can_discover_each_group_and_its_nodes_shape" {
  command = plan

  variables {
    node_labels = { workload = "reserved" }
    node_taints = ["workload=reserved:NoSchedule"]
  }

  assert {
    condition = alltrue([
      for key, value in {
        "k8s.io/cluster-autoscaler/enabled"                                              = "true"
        "k8s.io/cluster-autoscaler/bharat"                                               = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/workload"                         = "reserved"
        "k8s.io/cluster-autoscaler/node-template/label/kube-compute.io/node-group"       = "workers"
        "k8s.io/cluster-autoscaler/node-template/label/node.kubernetes.io/instance-type" = "t3a.xlarge"
        "k8s.io/cluster-autoscaler/node-template/taint/workload"                         = "reserved:NoSchedule"
        } : contains([
          for t in aws_autoscaling_group.node["t3a.xlarge"].tag : t.value if t.key == key && !t.propagate_at_launch
      ], value)
    ])
    error_message = "each group must carry the discovery tags, and advertise its labels and taints, or cluster-autoscaler cannot scale it from zero"
  }
  assert {
    condition     = output.node_labels["kube-compute.io/node-group"] == "workers" && output.node_labels["topology.kubernetes.io/zone"] == "eu-west-1a"
    error_message = "every node of the role must carry the same group and zone labels, whatever its size"
  }
}

run "an_invalid_taint_is_rejected" {
  command = plan

  variables {
    node_taints = ["workload:NoSchedule"]
  }

  expect_failures = [var.node_taints]
}

run "an_instance_type_with_no_room_is_rejected" {
  command = plan

  variables {
    instance_type_max_sizes = { "t3a.large" = 0 }
  }

  expect_failures = [var.instance_type_max_sizes]
}

run "os_image_name_resolves_for_each_instance_types_architecture" {
  command = plan

  override_data {
    target = data.aws_ami.by_name
    values = { id = "ami-byname789" }
  }

  variables {
    os_image_name = "almalinux10-*-kube-image-*"
  }

  assert {
    condition     = alltrue([for lt in aws_launch_template.node : lt.image_id == "ami-byname789"])
    error_message = "os_image_name should resolve to the looked-up AMI ID for every instance type"
  }
}
