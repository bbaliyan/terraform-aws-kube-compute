# SPDX-License-Identifier: Apache-2.0
# The sweep itself is a destroy-time provisioner, which no plan can execute. What a plan can
# show is the input it reads at that point -- the cluster whose volumes it matches and whether
# it is switched on -- and that the switch never lands in count, where turning it off would
# destroy the resource and so run the sweep against a cluster that is still running.

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

run "the_sweep_matches_this_cluster_in_its_own_region" {
  command = plan

  assert {
    condition     = terraform_data.volume_sweep.input.cluster_name == "bharat"
    error_message = "the sweep deletes by ClusterName tag, so it must carry this cluster's name and no other"
  }

  assert {
    condition     = terraform_data.volume_sweep.input.region == "eu-west-1"
    error_message = "volumes are regional; a sweep pointed at the wrong region silently deletes nothing"
  }

  assert {
    condition     = terraform_data.volume_sweep.input.enabled == true
    error_message = "cleanup is on by default: the default storage class reclaims volumes, so a destroy is expected to take them"
  }
}

run "turning_it_off_keeps_the_resource" {
  command = plan

  variables {
    orphan_volume_cleanup = false
  }

  assert {
    condition     = terraform_data.volume_sweep.input.enabled == false
    error_message = "the switch must reach the provisioner through input"
  }
}

# The sweep is created with the cluster, so anything the control plane reads that depends on it
# is deferred to apply. Choosing a subnet from subnet_names reads the cluster's existing control
# plane and counts on what it finds, which cannot be counted once deferred.
run "a_new_cluster_choosing_its_subnet_still_plans" {
  command = plan

  override_data {
    target = module.control_plane.data.aws_subnet.by_name
    values = { id = "subnet-pool123", available_ip_address_count = 250 }
  }

  variables {
    subnet_id    = null
    subnet_names = ["private-az1", "private-az2"]
  }

  assert {
    condition     = module.control_plane.subnet_id == "subnet-pool123"
    error_message = "a fresh cluster must plan when its subnet is chosen from subnet_names"
  }
}
