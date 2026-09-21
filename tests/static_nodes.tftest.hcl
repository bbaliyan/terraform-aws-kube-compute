# SPDX-License-Identifier: Apache-2.0
# Guards the composition wiring: subnet inheritance, platform placement and
# ingress, and all_instance_ids covering workers as well as the control plane.

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "no_static_nodes_creates_none" {
  command = plan

  assert {
    condition     = length(module.static_nodes) == 0
    error_message = "empty static_nodes map must create zero node groups"
  }
  assert {
    condition     = length(output.all_instance_ids) == 1
    error_message = "with no static nodes, all_instance_ids must be the genesis control-plane instance alone"
  }
  assert {
    condition     = length(aws_route53_record.platform_wildcard) == 0
    error_message = "without a platform group the control plane keeps its own wildcard record"
  }
}

run "groups_inherit_the_control_planes_subnet" {
  # apply, not plan: the wiring reads control-plane resource outputs, unknown at
  # plan time. Same reason composition.tftest.hcl's pool case uses apply.
  command = apply

  variables {
    static_nodes = {
      platform = {
        instance_type = "t4g.large"
        node_count    = 1
      }
      dedicated = {
        instance_type = "r5a.large"
        node_count    = 2
        node_taints   = ["dedicated=true:NoSchedule"]
        node_labels   = { "workload" = "reserved" }
      }
    }
  }

  assert {
    condition     = length(module.static_nodes) == 2
    error_message = "each static_nodes entry must create exactly one node group"
  }

  assert {
    condition = alltrue([
      for name, g in module.static_nodes : g.subnet_id == module.control_plane.subnet_id
    ])
    error_message = "a group given no subnet_id must land in the control plane's own subnet, and therefore its availability zone -- an EBS volume cannot cross zones"
  }

  assert {
    condition     = length(module.static_nodes["platform"].instance_ids) == 1 && length(module.static_nodes["dedicated"].instance_ids) == 2
    error_message = "node_count must control how many instances a group has"
  }

  assert {
    condition     = length(output.all_instance_ids) == 4
    error_message = "all_instance_ids must cover the control plane plus every static node (1 + 1 + 2), or a power schedule fed from it leaves the workers running around the clock"
  }

  assert {
    condition     = length(output.static_nodes["dedicated"].node_taints) == 1
    error_message = "the static_nodes output must surface each group's taints, so a consumer builds its tolerations from them rather than restating them"
  }

  assert {
    condition     = output.static_nodes["dedicated"].node_labels["kube-compute.io/node-group"] == "dedicated"
    error_message = "the group label must be derived from the map key, so a nodeSelector needs no separately-passed label"
  }

  # Derivation itself is asserted in aws-static-node's own tests, where the
  # instance-type data source can be overridden per run.
  assert {
    condition = alltrue([
      for name, g in output.static_nodes : contains(["arm64", "x86_64"], g.node_arch)
    ])
    error_message = "every group must report a resolved architecture, which is what its AMI lookup filtered on"
  }
}

run "platform_node_group_pins_the_platform_and_carries_its_iam" {
  command = apply

  variables {
    cluster_type        = "dedicated_control_plane"
    cluster_domain      = "eu-west-1.example.net"
    hosted_zone_id      = "Z0123456789ABCDEFGHIJ"
    platform_node_group = "platform"
    static_nodes = {
      platform = {
        instance_type = "t3a.xlarge"
      }
    }
  }

  assert {
    condition     = aws_route53_record.platform_wildcard[0].records == toset(values(module.static_nodes["platform"].private_ips))
    error_message = "the wildcard record must point at the platform node, where Traefik runs"
  }

  assert {
    condition     = local.platform_helm_values_object.platformNodeSelector["kube-compute.io/node-group"] == "platform"
    error_message = "the platform Application must be told to pin its components to the platform group's label"
  }
  assert {
    condition     = output.platform_node_iam_role_name == module.static_nodes["platform"].node_iam_role_name
    error_message = "platform controllers authenticate as the platform node, so their policies must target its role"
  }
  assert {
    condition     = output.workload_node_iam_role_names == [module.static_nodes["platform"].node_iam_role_name]
    error_message = "a dedicated control plane runs no workloads, so its role must not be among the workload roles"
  }
}

run "platform_node_group_must_name_a_static_group" {
  command = plan

  variables {
    platform_node_group = "missing"
  }

  expect_failures = [var.platform_node_group]
}

# A new cluster's subnet must hold every node that launches with it: the control
# plane plus each static node in its subnet. A group with its own subnet_id
# launches elsewhere and is not counted.
run "launch_ip_count_covers_static_nodes_in_the_subnet" {
  command = plan

  variables {
    subnet_id    = null
    subnet_names = ["private-az1", "private-az2"]
    static_nodes = {
      platform = {
        instance_type = "t4g.large"
        node_count    = 1
      }
      dedicated = {
        instance_type = "r5a.large"
        node_count    = 2
      }
      elsewhere = {
        instance_type = "t4g.large"
        node_count    = 5
        subnet_id     = "subnet-elsewhere"
      }
    }
  }

  override_data {
    target = module.control_plane.data.aws_subnet.by_name
    values = { id = "subnet-pool", available_ip_address_count = 250 }
  }

  assert {
    condition     = local.launch_ip_count == 4
    error_message = "launch_ip_count must be the control plane plus the 3 static nodes sharing its subnet, got ${local.launch_ip_count}"
  }
}
