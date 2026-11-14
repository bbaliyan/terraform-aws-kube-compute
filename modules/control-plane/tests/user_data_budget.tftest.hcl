# SPDX-License-Identifier: Apache-2.0
# EC2 rejects user data over 16384 decoded bytes (gzipped, as the instance
# sends it). The bootstrap program travels in user data, so this fixture builds
# a heavy genesis node and asserts the size stays below the limit with room to
# spare. The CA certificates are strings of base64 digests, which compress as
# little as real certificates do. A mock cannot show the real EC2 limit.
mock_provider "aws" {}

override_resource {
  target = random_password.server_token
  values = { result = "server-token-for-the-budget-test" }
}

override_resource {
  target = random_password.agent_token
  values = { result = "agent-token-for-the-budget-test" }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id             = "ami-0123456789abcdef0"
  cluster_name                = "heavy"
  aws_region                  = "eu-west-1"
  allowed_ingress_cidrs       = ["10.0.0.0/8"]
  subnet_id                   = "subnet-abc"
  control_plane_count         = 3
  endpoint_mode               = "static"
  static_registration_address = "cp.heavy.example.test"
  control_plane_subnets = {
    "eu-west-1a" = "subnet-az-a"
    "eu-west-1b" = "subnet-az-b"
    "eu-west-1c" = "subnet-az-c"
  }
  registry_mirror_url       = "https://mirror.example.test"
  gitops_workloads_repo_url = "https://example.test/workloads.git"
  trusted_ca_pem = join("\n", [
    for c in range(1) : "-----BEGIN CERTIFICATE-----\n${join("\n", [for i in range(17) : base64sha512("ca-${c}-${i}")])}\n-----END CERTIFICATE-----"
  ])
  platform_extra_helm_parameters = { for i in range(5) : "global.parameter${i}" => "value-${base64sha512("p${i}")}" }
  platform_helm_values_object = {
    tolerations = [for i in range(6) : { key = "key-${i}", operator = "Exists", effect = "NoSchedule" }]
  }
}

run "genesis_user_data_stays_under_the_ec2_limit" {
  command = plan

  assert {
    condition     = local.inline_user_data_bytes["0"] <= 15360
    error_message = "the heavy genesis user data must stay at or below 15360 bytes, 1024 under the EC2 limit of 16384. Measured: genesis ${nonsensitive(local.inline_user_data_bytes["0"])}, joining server ${nonsensitive(local.inline_user_data_bytes["1"])}."
  }
  assert {
    condition     = local.inline_user_data_bytes["1"] <= local.inline_user_data_bytes["0"]
    error_message = "a joining server must not need more user data than the genesis node"
  }
}
