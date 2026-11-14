# SPDX-License-Identifier: Apache-2.0
run "ssm_agent_is_always_a_step" {
  command = plan

  assert {
    condition     = [for step in output.steps : step.name] == ["ssm-agent"]
    error_message = "an AWS node always starts SSM Agent, and reads no instance metadata unless asked"
  }
}

run "the_provider_id_step_reads_instance_metadata" {
  command = plan

  variables {
    aws_provider_id = true
  }

  assert {
    condition     = [for step in output.steps : step.name] == ["ssm-agent", "aws-provider-id"]
    error_message = "aws_provider_id must add exactly one step after SSM Agent"
  }
  assert {
    condition     = strcontains(output.steps[1].commands[0][2], "provider-id=aws:///%s/%s") && strcontains(output.steps[1].commands[0][2], "node-label+:\\n  - \"node.kubernetes.io/instance-type=%s\"")
    error_message = "the drop-in must set the providerID and label the node with its instance type"
  }
}
