# SPDX-License-Identifier: Apache-2.0
# The bootstrap program travels in user data with its comment lines removed.
# The strip is a regex over lines, so it would also remove a line of a heredoc
# body that starts with "#". The steps use no heredoc, and these tests fail if one appears.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "SUPERSECRETTOKEN123"
  cluster_agent_token = "SUPERSECRETAGENT456"
}

run "no_step_has_a_heredoc" {
  command = plan

  variables {
    gitops_platform_repo_url = "https://example.test/platform.git"
    rejoin_probe_addresses   = ["10.0.0.9"]
  }

  assert {
    condition     = !strcontains(local.bootstrap_program, "<<")
    error_message = "a step must use no heredoc: the comment strip would remove a body line that starts with '#', and a file that cloud-init writes is the declarative way"
  }
  assert {
    condition     = length(local.boot_steps_enabled) > 10
    error_message = "the scan must see the steps of a genesis node that can rejoin, or it checks nothing"
  }
}

run "strip_keeps_the_shebang_and_code" {
  command = plan

  assert {
    condition     = startswith(local.bootstrap_program_inline, "#!/usr/bin/env bash\n")
    error_message = "the shebang must survive the comment strip"
  }
  assert {
    condition     = length(regexall("(?m)^[ \t]*#", replace(local.bootstrap_program_inline, "#!/usr/bin/env bash\n", ""))) == 0
    error_message = "no comment-only line may reach user data"
  }
  assert {
    condition     = length(regexall("(?m)^[ \t]*[^# \t\n]", local.bootstrap_program_inline)) == length(regexall("(?m)^[ \t]*[^# \t\n]", replace(local.bootstrap_program, "/(?m)^[ \t]*#.*\n/", "")))
    error_message = "the strip must remove comment-only lines and no code line"
  }
  assert {
    condition     = length(local.bootstrap_program_inline) < length(local.bootstrap_program)
    error_message = "the strip must make the program smaller"
  }
}

run "no_self_hash_remains" {
  command = plan

  assert {
    condition     = !strcontains(local.bootstrap_program, "KUBE_BOOTSTRAP_SHA256") && !strcontains(local.bootstrap_program, "sha256sum \"$0\"")
    error_message = "bootstrap.sh must not hash itself"
  }
}
