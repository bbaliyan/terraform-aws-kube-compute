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
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
}

# NOTE: the run blocks that used to live here (single_node_cni_defaults_to_default,
# ha_cni_defaults_to_cilium, explicit_cni_overrides_single_node_default,
# explicit_cni_overrides_ha_default) asserted on the `rendered_cloud_init`/
# `rendered_cloud_init_additional` outputs. Those outputs no longer exist — this
# module now hands `cni` to `node-bootstrap`, which renders it into config.yaml via
# Ansible at real-apply time, not into a Terraform-visible string. There is currently
# no automated test coverage for cni-default/override rendering; see rke2-ansible-bootstrap
# Ticket 14's resolution notes for the follow-up this needs.

run "invalid_cni_rejected" {
  command = plan
  variables {
    cni = "calico"
  }
  expect_failures = [var.cni]
}

run "cluster_sg_self_reference_covers_any_cni" {
  command = plan
  # aws-control-plane owns the cluster security group directly now (no separate
  # cluster-facts-style module); its self-referencing all-protocol rule already
  # covers every CNI's control-plane/pod-to-pod traffic regardless of the cni value.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing rule must remain all-protocol, CNI-agnostic"
  }
}
