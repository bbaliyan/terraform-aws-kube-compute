# SPDX-License-Identifier: Apache-2.0
# Each validation block of variables.tf rejects a bad value, and one good value still passes.
# expect_failures names the variable, so a run fails if the block stops rejecting.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
  node_role    = "server-init"
}

run "node_role_rejects_an_unknown_role" {
  command = plan

  variables {
    node_role = "agent"
  }

  expect_failures = [var.node_role]
}

run "node_role_accepts_worker" {
  command = plan

  variables {
    node_role                 = "worker"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
  }
}

run "cert_mode_rejects_an_unknown_mode" {
  command = plan

  variables {
    cert_mode = "letsencrypt"
  }

  expect_failures = [var.cert_mode]
}

run "cert_mode_accepts_acme" {
  command = plan

  variables {
    cert_mode = "acme"
  }
}

run "node_taints_rejects_an_entry_without_an_effect" {
  command = plan

  variables {
    node_taints = ["dedicated=true"]
  }

  expect_failures = [var.node_taints]
}

run "node_taints_rejects_an_unknown_effect" {
  command = plan

  variables {
    node_taints = ["dedicated=true:Evict"]
  }

  expect_failures = [var.node_taints]
}

run "node_taints_rejects_a_value_with_an_equals_sign" {
  command = plan

  variables {
    node_taints = ["dedicated=a=b:NoSchedule"]
  }

  expect_failures = [var.node_taints]
}

run "graceful_shutdown_rejects_critical_seconds_that_fill_the_window" {
  command = plan

  variables {
    graceful_shutdown = { seconds = 30, critical_seconds = 30 }
  }

  expect_failures = [var.graceful_shutdown]
}

run "graceful_shutdown_rejects_zero_critical_seconds" {
  command = plan

  variables {
    graceful_shutdown = { seconds = 90, critical_seconds = 0 }
  }

  expect_failures = [var.graceful_shutdown]
}

run "graceful_shutdown_accepts_null" {
  command = plan

  variables {
    graceful_shutdown = null
  }
}

run "provider_steps_rejects_a_duplicate_name" {
  command = plan

  variables {
    provider_steps = [
      { name = "mount", commands = [["true"]] },
      { name = "mount", commands = [["true"]] },
    ]
  }

  expect_failures = [var.provider_steps]
}

run "provider_steps_accepts_unique_names" {
  command = plan

  variables {
    provider_steps = [
      { name = "mount", commands = [["true"]] },
      { name = "route", commands = [["true"]] },
    ]
  }
}
