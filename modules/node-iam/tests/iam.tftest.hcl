# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "mock-account" }
}

variables {
  name_prefix = "kube-compute-example-"
  tags        = { ManagedBy = "kube-compute" }
  aws_region  = "eu-west-1"
}

run "defaults_attach_ssm_and_ebs_csi_without_an_agent_token_policy" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "the role must carry the SSM core policy"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi) == 1 && length(aws_iam_role_policy.agent_token) == 0
    error_message = "EBS CSI must be on by default and the agent token policy off"
  }

  assert {
    condition     = jsondecode(aws_iam_role.node.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com"
    error_message = "only EC2 may assume the node role"
  }
}

run "ebs_csi_can_be_left_off" {
  command = plan

  variables {
    attach_ebs_csi_policy = false
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi) == 0
    error_message = "attach_ebs_csi_policy = false must drop the EBS CSI attachment"
  }
}

run "agent_token_policy_reads_only_the_named_parameter" {
  command = plan

  variables {
    agent_token = {
      policy_name   = "kube-compute-example-agent-token-read"
      ssm_parameter = "/kube-compute/example/agent-token"
    }
  }

  assert {
    condition     = aws_iam_role_policy.agent_token[0].name == "kube-compute-example-agent-token-read"
    error_message = "the policy must take its name from the caller"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.agent_token[0].policy).Statement[0] == {
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = "arn:aws:ssm:eu-west-1:mock-account:parameter/kube-compute/example/agent-token"
    }
    error_message = "the role must read exactly the agent token parameter, in this region and account"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.agent_token[0].policy).Statement[1].Condition.StringEquals["kms:ViaService"] == "ssm.eu-west-1.amazonaws.com"
    error_message = "kms:Decrypt must be limited to calls made through SSM in the region"
  }
}

run "a_name_prefix_of_38_characters_is_accepted" {
  command = plan

  variables {
    name_prefix = "c0123456789012345678901234567890123456"
  }

  assert {
    condition     = length(aws_iam_role.node.name_prefix) == 38
    error_message = "a 38-character name_prefix must be accepted"
  }
}

run "a_name_prefix_over_38_characters_is_rejected" {
  command = plan

  variables {
    name_prefix = "c01234567890123456789012345678901234567"
  }

  expect_failures = [var.name_prefix]
}
