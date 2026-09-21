# SPDX-License-Identifier: Apache-2.0
# aws_lb/aws_lb_target_group's arn attribute is fed straight back into other resources'
# load_balancer_arn/target_group_arn arguments, which the AWS provider's own schema validates
# as ARN-shaped — the mock provider's default random string for a computed "arn" attribute
# fails that validation. Static, valid-looking ARNs sidestep it (mirrors the aws_launch_template
# mock_resource pattern already used in aws-node-pool/tests/pool.tftest.hcl).
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
}

run "control_plane_count_3_places_one_per_az_behind_nlb" {
  command = plan
  variables {
    control_plane_count = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
  }
  assert {
    condition     = length(aws_instance.control_plane_additional) == 2
    error_message = "control_plane_count=3 must plan the genesis node plus 2 additional control-plane nodes"
  }
  assert {
    condition     = length(aws_lb.control_plane) == 1
    error_message = "control_plane_count=3 must plan an internal NLB"
  }
  assert {
    condition     = aws_lb.control_plane[0].internal == true
    error_message = "the control-plane NLB must be internal"
  }
  assert {
    condition     = aws_lb.control_plane[0].load_balancer_type == "network"
    error_message = "the control-plane LB must be a Network Load Balancer"
  }
  assert {
    condition     = aws_lb_listener.control_plane[0].port == 6443
    error_message = "the NLB must listen on 6443"
  }
  assert {
    condition     = length(aws_lb_target_group_attachment.additional) == 2
    error_message = "every additional control-plane node must attach to the NLB target group"
  }
  assert {
    condition     = length(aws_lb_target_group_attachment.genesis) == 1
    error_message = "the genesis control-plane node must attach to the NLB target group too"
  }
  assert {
    condition     = aws_security_group.cluster.vpc_id == data.aws_subnet.control_plane_genesis[0].vpc_id
    error_message = "in HA mode, the cluster SG must be created in the same VPC as the control-plane subnets, not the unused single-node fallback"
  }
}

run "control_plane_count_5_places_one_per_az" {
  command = plan
  variables {
    control_plane_count = 5
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
      "eu-west-1d" = "subnet-az-d"
      "eu-west-1e" = "subnet-az-e"
    }
  }
  assert {
    condition     = length(aws_instance.control_plane_additional) == 4
    error_message = "control_plane_count=5 must plan the genesis node plus 4 additional control-plane nodes"
  }
}

run "control_plane_count_5_round_robins_when_fewer_than_five_azs" {
  command = plan
  variables {
    control_plane_count = 5
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
  }
  assert {
    condition     = length(aws_instance.control_plane_additional) == 4
    error_message = "control_plane_count=5 with only 3 AZs available must still plan 5 nodes total (genesis + 4 additional), cycling through the 3 AZs rather than failing"
  }
  assert {
    condition     = length(aws_lb.control_plane[0].subnets) == 3
    error_message = "the NLB must list each distinct AZ's subnet exactly once, even when control_plane_count exceeds the number of available AZs — AWS's real NLB API rejects duplicate/repeated subnets"
  }
}

run "empty_control_plane_subnets_map_declines_cleanly" {
  command = plan
  variables {
    control_plane_count   = 3
    control_plane_subnets = {}
  }
  expect_failures = [aws_instance.control_plane]
}

run "fewer_than_three_azs_declines" {
  command = plan
  variables {
    control_plane_count = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
    }
  }
  expect_failures = [aws_instance.control_plane]
}

run "ha_registration_address_is_nlb_and_refs_include_all_nodes" {
  command = plan
  variables {
    control_plane_count = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
  }
  assert {
    condition     = output.registration_address == aws_lb.control_plane[0].dns_name
    error_message = "for control_plane_count > 1, registration_address must be the NLB's dns_name, not a node IP"
  }
  assert {
    condition     = length(keys(output.control_plane_node_refs)) == 3
    error_message = "control_plane_node_refs must include all 3 control-plane nodes, not just the genesis one"
  }
}
