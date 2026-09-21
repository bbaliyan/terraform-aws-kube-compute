# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
}

run "cluster_sg_is_self_referencing" {
  command = plan
  # aws-control-plane now generates its own join tokens and owns the cluster security
  # group directly (no separate cluster-facts-style module) — matching
  # proxmox-control-plane's precedent.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.referenced_security_group_id == aws_security_group.cluster.id
    error_message = "the cluster SG must allow traffic sourced from itself"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing rule must be all-protocol, CNI-agnostic"
  }
  assert {
    condition     = output.cluster_security_group_id == aws_security_group.cluster.id
    error_message = "cluster_security_group_id output must expose the cluster SG id"
  }
  assert {
    condition     = contains(aws_instance.control_plane.vpc_security_group_ids, aws_security_group.cluster.id)
    error_message = "the control-plane instance must attach the cluster SG"
  }
}

run "agent_token_ssm_parameter_output" {
  command = plan
  assert {
    condition     = aws_ssm_parameter.agent_token.type == "SecureString"
    error_message = "agent-token SSM parameter must be stored as SecureString, never plaintext"
  }
  assert {
    condition     = output.agent_token_ssm_parameter == aws_ssm_parameter.agent_token.name
    error_message = "agent_token_ssm_parameter output must expose the SSM parameter's own name"
  }
}

run "etcd_sg_is_control_plane_only" {
  command = plan
  assert {
    condition     = aws_vpc_security_group_ingress_rule.etcd_peer.from_port == 2379 && aws_vpc_security_group_ingress_rule.etcd_peer.to_port == 2380
    error_message = "the etcd SG must open exactly 2379-2380"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.etcd_peer.referenced_security_group_id == aws_security_group.control_plane_etcd.id
    error_message = "etcd traffic must be scoped to a control-plane-only SG, not the general cluster SG workers also join"
  }
  assert {
    condition     = contains(aws_instance.control_plane.vpc_security_group_ids, aws_security_group.control_plane_etcd.id)
    error_message = "the control-plane instance must attach the etcd-only SG"
  }
}

run "registration_address_and_node_refs" {
  command = plan
  assert {
    condition     = output.registration_address == aws_instance.control_plane.private_ip
    error_message = "for control_plane_count=1, registration_address must be the sole control-plane node's private IP"
  }
  assert {
    condition     = keys(output.control_plane_node_refs) == ["bharat-cp-1"]
    error_message = "control_plane_node_refs must map a deterministic node name to its ref"
  }
  assert {
    condition     = output.control_plane_node_refs["bharat-cp-1"].instance_id == aws_instance.control_plane.id
    error_message = "each node ref must carry the instance id"
  }
  assert {
    condition     = output.control_plane_node_refs["bharat-cp-1"].provider == "aws"
    error_message = "each node ref must report its provider"
  }
}
