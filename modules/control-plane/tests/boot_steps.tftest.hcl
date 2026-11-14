# SPDX-License-Identifier: Apache-2.0
# Pins the exact boot steps of every control-plane node on AWS. A step that belongs to
# another provider (DNS self-registration, an iSCSI initiator name) cannot appear here,
# and the AWS steps (SSM Agent, the provider ID) are here. Plan only: nothing is created.
mock_provider "aws" {}

override_resource {
  target = random_password.server_token
  values = { result = "server-token-for-the-steps-test" }
}

override_resource {
  target = random_password.agent_token
  values = { result = "agent-token-for-the-steps-test" }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id             = "ami-0123456789abcdef0"
  cluster_name                = "steps"
  aws_region                  = "eu-west-1"
  allowed_ingress_cidrs       = ["10.0.0.0/8"]
  subnet_id                   = "subnet-abc"
  control_plane_count         = 3
  endpoint_mode               = "static"
  static_registration_address = "cp.steps.example.test"
  control_plane_subnets = {
    "eu-west-1a" = "subnet-az-a"
    "eu-west-1b" = "subnet-az-b"
    "eu-west-1c" = "subnet-az-c"
  }
}

run "genesis_and_joining_server_steps" {
  command = plan

  assert {
    condition = module.node_bootstrap["0"].boot_steps == [
      "ssm-agent",
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "rejoin-probe",
      "node-config-server",
      "platform-clone",
      "api-skew-check",
      "genesis-cilium-manifest",
      "start-server-init",
      "start-server-join",
      "wait-ready-server",
      "genesis-cilium-handoff",
      "genesis-argocd",
      "finish",
      "os-auto-updates",
    ]
    error_message = "the AWS genesis node must run exactly these steps"
  }

  assert {
    condition = module.node_bootstrap["1"].boot_steps == [
      "ssm-agent",
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "node-config-server",
      "api-skew-check",
      "start-server-join",
      "wait-ready-server",
      "finish",
      "os-auto-updates",
    ]
    error_message = "the AWS joining server must run exactly these steps"
  }

  assert {
    condition     = module.node_bootstrap["2"].boot_steps == module.node_bootstrap["1"].boot_steps
    error_message = "every joining server runs the same steps"
  }
}

run "the_provider_id_step_is_added_when_asked_for" {
  command = plan

  variables {
    aws_provider_id = true
  }

  assert {
    condition     = slice(module.node_bootstrap["0"].boot_steps, 0, 3) == ["ssm-agent", "aws-provider-id", "kubelet-reserved"]
    error_message = "aws_provider_id must add its step after SSM Agent and before the module's own commands"
  }
}

run "no_proxmox_step_reaches_an_aws_node" {
  command = plan

  variables {
    aws_provider_id = true
  }

  assert {
    condition = !anytrue([
      for name in concat(module.node_bootstrap["0"].boot_steps, module.node_bootstrap["1"].boot_steps) :
      contains(["dns-self-register", "iscsi-initiator"], name)
    ])
    error_message = "DNS self-registration and the iSCSI initiator name are Proxmox steps"
  }
  assert {
    condition     = !strcontains(nonsensitive(module.node_bootstrap["0"].cloud_init_user_data), "nsupdate") && !strcontains(nonsensitive(module.node_bootstrap["0"].cloud_init_user_data), "iscsi")
    error_message = "the user data of an AWS node must name neither nsupdate nor iSCSI"
  }
}
