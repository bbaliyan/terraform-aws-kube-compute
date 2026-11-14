# SPDX-License-Identifier: Apache-2.0
# The first server clones the platform ref before RKE2 starts and takes the Cilium
# and Argo CD manifests from bootstrap/rendered/ in the clone. This module passes the
# repo and the revision to bootstrap.sh in node.env. What the script does with them
# cannot run here: these tests assert the values it is handed and the shape of the
# program.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
}

run "genesis_with_the_defaults_clones_the_pinned_ref" {
  command = plan
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REPO_URL='https://github.com/bbaliyan/kube-platform.git'")
      && strcontains(base64decode(f.content), "PLATFORM_REVISION='main'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "node.env must carry the pinned platform repo and revision on a genesis node"
  }
}

run "genesis_clones_the_ref_the_platform_application_tracks" {
  command = plan
  variables {
    gitops_platform_repo_url = "https://mirror.example.test/platform.git"
    gitops_platform_revision = "release-7"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REPO_URL='https://mirror.example.test/platform.git'")
      && strcontains(base64decode(f.content), "PLATFORM_REVISION='release-7'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "node.env must carry the same repo and revision as the platform Application"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "release-7")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "the platform Application must track the revision that node.env clones"
  }
}

run "a_commit_sha_reaches_node_env_unchanged" {
  command = plan
  variables {
    gitops_platform_revision = "0123456789abcdef0123456789abcdef01234567"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REVISION='0123456789abcdef0123456789abcdef01234567'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a commit SHA must reach node.env as given; bootstrap.sh decides how to fetch it"
  }
}

run "a_joining_server_clones_nothing" {
  command = plan
  variables {
    node_role = "server-join"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REPO_URL=''") && strcontains(base64decode(f.content), "PLATFORM_REVISION=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "only the genesis node clones the platform ref; the keys must still be defined, but empty"
  }
}

run "a_worker_clones_nothing" {
  command = plan
  variables {
    node_role = "worker"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REPO_URL=''") && strcontains(base64decode(f.content), "PLATFORM_REVISION=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a worker must not clone the platform ref"
  }
}

run "genesis_with_cilium_and_no_platform_needs_a_repo" {
  command = plan
  variables {
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
  }
  expect_failures = [output.cloud_init_user_data]
}

run "genesis_with_argocd_for_workloads_and_no_platform_needs_a_repo" {
  command = plan
  variables {
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = "https://example.test/workloads.git"
  }
  expect_failures = [output.cloud_init_user_data]
}

run "genesis_with_cilium_and_no_platform_accepts_a_named_repo" {
  command = plan
  variables {
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
    gitops_platform_repo_url  = "https://mirror.example.test/platform.git"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REPO_URL='https://mirror.example.test/platform.git'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a named repo must reach node.env when the platform Application is off"
  }
}

run "a_joining_server_needs_no_repo" {
  command = plan
  variables {
    node_role                 = "server-join"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
  }
  assert {
    condition     = output.node_name == "test-cp-0"
    error_message = "only the genesis node needs the platform repo"
  }
}

run "the_program_starts_with_a_tool_check_that_lists_every_missing_tool" {
  command = plan
  assert {
    condition     = strcontains(local.bootstrap_program, "for tool in git curl getent ip awk systemctl; do\n  command -v \"$tool\" >/dev/null 2>&1 || MISSING_TOOLS=\"$MISSING_TOOLS $tool\"\ndone\n")
    error_message = "bootstrap.sh must check every tool with command -v and collect the missing ones"
  }
  assert {
    condition = (
      strcontains(local.bootstrap_program, "the image lacks these tools:$MISSING_TOOLS")
      && length(split("command -v", local.bootstrap_program)[0]) < length(split(". \"$KC/node.env\"", local.bootstrap_program)[0])
    )
    error_message = "the tool check must report all missing tools in one message, before node.env is read"
  }
}

run "the_cilium_manifest_comes_from_the_clone_not_the_image" {
  command = plan
  assert {
    condition     = strcontains(local.bootstrap_program, "install -m 0600 \"$PLATFORM_DIR/bootstrap/rendered/cilium.yaml\" /var/lib/rancher/rke2/server/manifests/cilium.yaml")
    error_message = "the Cilium manifest must be installed from bootstrap/rendered/ in the clone"
  }
  assert {
    condition     = !strcontains(local.bootstrap_program, "$KC/manifests/cilium.yaml")
    error_message = "bootstrap.sh must not read an image-baked Cilium manifest"
  }
}

run "the_clone_happens_before_rke2_starts_and_retries" {
  command = plan
  assert {
    condition = (
      strcontains(local.bootstrap_program, "git clone -q --depth 1 --branch \"$PLATFORM_REVISION\" \"$PLATFORM_REPO_URL\" \"$PLATFORM_DIR\"")
      && strcontains(local.bootstrap_program, "git clone -q --filter=blob:none --no-checkout \"$PLATFORM_REPO_URL\" \"$PLATFORM_DIR\"")
      && strcontains(local.bootstrap_program, "git -C \"$PLATFORM_DIR\" checkout -q \"$PLATFORM_REVISION\"")
      && strcontains(local.bootstrap_program, "for _ in 1 2 3 4 5; do\n    if clone_platform; then")
    )
    error_message = "bootstrap.sh must clone a branch or tag shallowly, check out a commit SHA, and retry five times"
  }
  assert {
    condition = (
      length(split("if clone_platform; then", local.bootstrap_program)[0]) < length(split("systemctl enable --now rke2-server.service", local.bootstrap_program)[0])
      && length(split("if clone_platform; then", local.bootstrap_program)[0]) < length(split("install -m 0600 \"$PLATFORM_DIR/bootstrap/rendered/cilium.yaml\"", local.bootstrap_program)[0])
    )
    error_message = "the clone must come before the Cilium file is copied and before RKE2 starts"
  }
}

run "a_missing_rendered_file_stops_the_boot_with_one_line" {
  command = plan
  assert {
    condition = (
      strcontains(local.bootstrap_program, "echo \"kube-compute: $PLATFORM_REPO_URL at $PLATFORM_REVISION has no $1\" >&2")
      && strcontains(local.bootstrap_program, "for required_file in $PLATFORM_REQUIRED_FILES; do")
    )
    error_message = "bootstrap.sh must stop, naming the repo, the ref and the path, when a rendered file is missing"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REQUIRED_FILES='bootstrap/rendered/cilium.yaml bootstrap/rendered/argocd.yaml'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "node.env must list the rendered files a genesis node with Cilium and Argo CD requires"
  }
}

run "argocd_is_applied_from_the_clone_after_ready" {
  command = plan
  assert {
    condition     = strcontains(local.bootstrap_program, "$KUBECTL apply --server-side --force-conflicts -f \"$PLATFORM_DIR/bootstrap/rendered/argocd.yaml\"")
    error_message = "Argo CD must be applied server-side from bootstrap/rendered/argocd.yaml in the clone"
  }
  assert {
    condition     = length(split("CoreDNS Ready", local.bootstrap_program)[0]) < length(split("bootstrap/rendered/argocd.yaml\"\n", local.bootstrap_program)[0])
    error_message = "Argo CD must be applied after the node is Ready and CoreDNS is up"
  }
  assert {
    condition     = !strcontains(local.bootstrap_program, "curl -fsSL") && !strcontains(local.bootstrap_program, "sha256sum -c")
    error_message = "bootstrap.sh must not download or hash an Argo CD manifest"
  }
}

run "the_rke2_skew_check_compares_the_image_with_the_platform_and_the_api_server" {
  command = plan
  variables {
    rejoin_probe_addresses = ["10.0.0.9"]
  }
  assert {
    condition = (
      strcontains(local.bootstrap_program, "image=\"$(rke2 --version | awk 'NR == 1 {print $3}')\"")
      && strcontains(local.bootstrap_program, "sort -V | tail -n 1")
      && strcontains(local.bootstrap_program, "local image image_minor target_minor newest")
      && strcontains(local.bootstrap_program, "check_rke2_skew \"$PLATFORM_K8S_VERSION\"")
      && strcontains(local.bootstrap_program, "awk '$1 == \"k8sVersion:\" {print $2}' \"$PLATFORM_DIR/platform/platform-versions/values.yaml\"")
      && strcontains(local.bootstrap_program, "check_rke2_skew \"$API_VERSION\" \"the API server\"")
    )
    error_message = "bootstrap.sh must compare rke2 --version with k8sVersion from the clone on the genesis node, and with the API server version on a joining server"
  }
  assert {
    condition     = length(split("check_rke2_skew \"$PLATFORM_K8S_VERSION\"", local.bootstrap_program)[0]) < length(split("systemctl enable --now rke2-server.service", local.bootstrap_program)[0])
    error_message = "the skew check must stop the boot before RKE2 starts"
  }
}
