# SPDX-License-Identifier: Apache-2.0
# Covers the taint half of a dedicated node (node_labels is already covered by
# cloud_init_render.tftest.hcl), plus the two cases where it must not render.

variables {
  cluster_name = "test"
  node_name    = "test-worker-0"
}

run "worker_renders_every_taint_quoted" {
  command = plan

  variables {
    node_role                 = "worker"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    node_labels               = { "kube-compute.io/role" = "dedicated" }
    node_taints = [
      "dedicated=true:NoSchedule",
      "kube-compute.io/drain=pending:NoExecute",
    ]
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "node-taint:") &&
      strcontains(base64decode(f.content), "  - \"dedicated=true:NoSchedule\"") &&
      strcontains(base64decode(f.content), "  - \"kube-compute.io/drain=pending:NoExecute\"")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "a worker's config.yaml render must carry every node_taints entry under a single node-taint: key, each quoted"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "node-label:") &&
      strcontains(base64decode(f.content), "kube-compute.io/role=dedicated")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "taints must not displace labels — a dedicated node needs both, the label to be selected by and the taint to keep others off"
  }
}

run "empty_list_renders_no_taint_key" {
  command = plan

  variables {
    node_role                 = "worker"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "node-taint:")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "the default empty list must leave config.yaml with no node-taint: key at all, not an empty one"
  }
}

run "server_init_taint_still_comes_from_control_plane_taint" {
  command = plan

  variables {
    node_role           = "server-init"
    node_name           = "test-cp-1"
    cluster_token       = "SUPERSECRETTOKEN123"
    control_plane_taint = true
    # Deliberately set on a server role, where it must be ignored.
    node_taints = ["dedicated=true:NoSchedule"]
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "CriticalAddonsOnly=true:NoExecute")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "control_plane_taint must still render the CriticalAddonsOnly taint on a server node"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "dedicated=true:NoSchedule")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "node_taints must be ignored on a server role — rendering it would emit a second node-taint: key and RKE2 refuses to start on duplicate config.yaml keys"
  }
}
