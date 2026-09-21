# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["x86_64"]
      default_vcpus           = 2
      memory_size             = 8192
    }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "no_roles_means_no_autoscaling" {
  command = plan

  assert {
    condition     = length(module.autoscaled_nodes) == 0 && length(aws_iam_role_policy.autoscaling) == 0 && length(aws_iam_role_policy.cloud_controller_manager) == 0
    error_message = "without autoscaled_nodes nothing may be created for autoscaling"
  }
  assert {
    condition     = length(local.platform_extra_helm_parameters) == 0
    error_message = "without autoscaled_nodes the platform Application must be unchanged, or every existing control plane is replaced"
  }
}

# Every mocked instance type has 2 vCPUs and 8 GiB.
run "a_role_scales_every_size_within_the_limits" {
  command = apply

  variables {
    cluster_type        = "dedicated_control_plane"
    platform_node_group = "platform"
    static_nodes = {
      platform = { instance_type = "t3a.xlarge" }
    }
    autoscaled_nodes = {
      workers = {
        instance_types = ["t3a.large", "t3a.xlarge"]
        max_cpu_cores  = 6
        max_memory_gib = 20
        node_taints    = ["workload=shared:PreferNoSchedule"]
      }
      reserved = {
        instance_types = ["r5a.large"]
        max_cpu_cores  = 2
        max_memory_gib = 8
      }
    }
  }

  assert {
    condition = (
      alltrue([for group in module.autoscaled_nodes["workers"].autoscaling_groups : group.max_size == 2]) &&
      module.autoscaled_nodes["reserved"].autoscaling_groups["r5a.large"].max_size == 1
    )
    error_message = "each size's group may hold only as many instances as fit its role's caps: 20 GiB fits two 8 GiB nodes"
  }
  assert {
    condition = (
      local.platform_extra_helm_parameters.clusterAutoscalerCoresTotal == "0:12" &&
      local.platform_extra_helm_parameters.clusterAutoscalerMemoryTotal == "0:44"
    )
    error_message = "the autoscaler's totals must be every role's caps plus the control plane and static nodes, which it counts too"
  }
  assert {
    condition = (
      local.platform_extra_helm_parameters.clusterAutoscalerEnabled == "true" &&
      local.platform_extra_helm_parameters.clusterAutoscalerCloudProvider == "aws" &&
      local.platform_extra_helm_parameters.awsRegion == "eu-west-1"
    )
    error_message = "the platform Application must run cluster-autoscaler against this region's Auto Scaling groups"
  }
  assert {
    condition     = module.autoscaled_nodes["workers"].subnet_id == module.control_plane.subnet_id
    error_message = "every group must launch into the control plane's subnet -- an EBS volume cannot cross availability zones"
  }
  assert {
    condition     = aws_iam_role_policy.autoscaling[0].role == module.static_nodes["platform"].node_iam_role_name
    error_message = "the autoscaler runs on the platform node, so its role must carry the autoscaler's permissions"
  }
  assert {
    condition     = aws_iam_role_policy.cloud_controller_manager[0].role == module.control_plane.node_iam_role_name
    error_message = "the cloud controller manager runs on the control plane, so its role must carry the controller's permissions"
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.autoscaling[0].policy).Statement[1].Resource) == toset(flatten([for role in module.autoscaled_nodes : [for group in values(role.autoscaling_groups) : group.arn]]))
    error_message = "scaling and terminating must be limited to this cluster's own groups"
  }
  assert {
    condition     = contains(output.workload_node_iam_role_names, module.autoscaled_nodes["workers"].node_iam_role_name)
    error_message = "workloads run on autoscaled nodes, so their role must be among the workload roles"
  }
}

run "an_instance_type_larger_than_its_roles_caps_is_rejected" {
  command = plan

  variables {
    autoscaled_nodes = {
      workers = { instance_types = ["t3a.large"], max_cpu_cores = 1, max_memory_gib = 64 }
    }
  }

  expect_failures = [terraform_data.autoscaling_limits]
}

run "a_role_without_caps_is_rejected" {
  command = plan

  variables {
    autoscaled_nodes = {
      workers = { instance_types = ["t3a.large"], max_cpu_cores = 0, max_memory_gib = 0 }
    }
  }

  expect_failures = [var.autoscaled_nodes]
}

run "autoscaling_without_the_platform_is_rejected" {
  command = plan

  variables {
    gitops_platform_enabled = false
    autoscaled_nodes = {
      workers = { instance_types = ["t3a.large"], max_cpu_cores = 8, max_memory_gib = 32 }
    }
  }

  expect_failures = [var.autoscaled_nodes]
}
