# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

variables {
  cluster_name          = "app-red"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
  cluster_domain        = "red.example.internal"
  hosted_zone_id        = "Z0123456789ABCDEFGHIJ"
}

run "without_it_the_dns_name_is_the_cluster_name" {
  command = plan

  assert {
    condition     = output.cluster_fqdn == "api.app-red.red.example.internal"
    error_message = "unset, cluster_dns_name must leave the name as it was: got ${output.cluster_fqdn}"
  }
}

run "the_domain_can_carry_what_the_name_repeats" {
  command = plan

  variables {
    cluster_dns_name = "app"
  }

  assert {
    condition     = output.cluster_fqdn == "api.app.red.example.internal"
    error_message = "the FQDN must use cluster_dns_name: got ${output.cluster_fqdn}"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.app.red.example.internal"
    error_message = "the wildcard must follow the FQDN: got ${output.wildcard_dns_name}"
  }
}

run "resources_stay_on_the_cluster_name" {
  command = plan

  variables {
    cluster_dns_name = "app"
  }

  assert {
    condition     = output.agent_token_ssm_parameter == "/kube-compute/app-red/agent-token"
    error_message = "the agent token parameter must stay unique per cluster_name, not per DNS name: got ${output.agent_token_ssm_parameter}"
  }
  assert {
    condition     = output.cluster_name == "app-red"
    error_message = "the cluster keeps its own identity whatever it is called in DNS"
  }
}
