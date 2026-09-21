# SPDX-License-Identifier: Apache-2.0
# Regression test for a real bug hit on a live apply: a caller (a
# *-control-plane module) passing an explicit null (or "") for
# gitops_platform_repo_url/_revision — the normal "no override" case — must
# fall back to the pinned kube-platform coordinates. It does NOT do so for free
# via Terraform's module-argument defaulting (that convenience is specific to
# optional() object-type attributes, not plain string variables passed through
# a module call). coalesce() in main.tf's effective_gitops_platform_repo_url/
# _revision locals is the actual fix; this test locks it in against the
# cloud-init payload the same way it used to against the Ansible extra-vars.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
}

run "null_repo_url_falls_back_to_the_pin" {
  command = plan
  variables {
    gitops_platform_repo_url = null
    gitops_platform_revision = null
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kube-platform.git")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "an explicit null gitops_platform_repo_url must fall back to the pinned kube-platform repo, not resolve to a literal null"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "repoURL: null") &&
      !strcontains(base64decode(f.content), "targetRevision: null")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "a literal null must never reach the platform Application manifest"
  }
}

run "empty_string_repo_url_also_falls_back_to_the_pin" {
  command = plan
  variables {
    gitops_platform_repo_url = ""
    gitops_platform_revision = ""
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kube-platform.git")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "an explicit empty-string gitops_platform_repo_url must also fall back to the pin (cluster-facts re-exports unset overrides as \"\", not null)"
  }
}

run "explicit_override_still_wins" {
  command = plan
  variables {
    gitops_platform_repo_url = "https://example.test/fork.git"
    gitops_platform_revision = "v9.9.9"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "example.test/fork.git") &&
      !strcontains(base64decode(f.content), "kube-platform.git")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "an explicit override must take effect and the pin must not leak through alongside it"
  }
}

run "disabled_platform_renders_no_application_at_all" {
  command = plan
  variables {
    gitops_platform_enabled = false
  }
  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/10-platform-app.yaml"
    )
    error_message = "gitops_platform_enabled = false must skip the platform Application entirely, even though the pin would otherwise apply"
  }
  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/00-argocd.yaml"
    )
    error_message = "with no platform and no workloads Application, Argo CD itself must not be installed either"
  }
}
