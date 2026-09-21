# SPDX-License-Identifier: Apache-2.0
# Guards the generic genesis_apply_manifests/cluster_autoscaler_crd_wait_enabled
# mechanism that replaced the old bespoke cluster_autoscaler_* toggle: disabled
# (the default, empty list) must leave zero trace in the rendered payload;
# populated must carry every write_files entry the caller listed plus the
# CAPI-install/CRD-wait/ordered-apply steps in bootstrap.sh, server-init only.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
}

run "genesis_apply_manifests_empty_by_default_leaves_no_trace" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "genesis_apply_manifests defaults to an empty list — nothing beyond the platform/workloads Applications should be written"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "CAPI_CRD_WAIT_ENABLED='0'") &&
      strcontains(base64decode(f.content), "GENESIS_APPLY_MANIFESTS=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "with cluster_autoscaler_crd_wait_enabled = false (the default), the node must be told to wait for nothing and apply nothing"
  }
}

run "genesis_apply_manifests_renders_entries_and_apply_steps" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null

    cluster_autoscaler_crd_wait_enabled = true
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
        content = "kind: Cluster\nname: test-autoscaler-workers\n"
      }
    ]
  }

  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "a genesis_apply_manifests entry on a server-init node must be written via write_files"
  }
  # Compared against base64gzip of the input rather than decoded, because a
  # genesis manifest is written gz+b64 to stay inside EC2's user-data cap and HCL
  # has no gunzip. Byte equality proves the content was not interpreted, which is
  # what this guards.
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      f.encoding == "gz+b64" &&
      f.content == base64gzip("kind: Cluster\nname: test-autoscaler-workers\n")
      if f.path == "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    ])
    error_message = "this module must not interpret genesis_apply_manifests content — it must be written back out verbatim, compressed but unaltered"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "CAPI_CRD_WAIT_ENABLED='1'") &&
      strcontains(base64decode(f.content), "CAPI_INSTALL_BAKED='1'") &&
      strcontains(base64decode(f.content), "GENESIS_APPLY_MANIFESTS='/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "the node must be told to install the baked capi-install.yaml, wait for CAPI's CRDs, and which manifests to apply in order"
  }
  # The other half of that contract, in the program rather than the payload.
  assert {
    condition = alltrue([
      for line in [
        "$KUBECTL apply -f \"$KC/manifests/capi-install.yaml\"",
        "machinedeployments.cluster.x-k8s.io",
        "for manifest_path in $GENESIS_APPLY_MANIFESTS",
      ] : strcontains(local.bootstrap_program, line)
    ])
    error_message = "the baked program must still install capi-install.yaml, wait for CAPI's CRDs, and apply the listed manifests in order"
  }
}

run "genesis_apply_manifests_worker_node_never_renders_the_genesis_apply" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"

    cluster_autoscaler_crd_wait_enabled = true
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "the genesis apply mechanism is server-init-only — a plain worker must never carry it, even with genesis_apply_manifests populated"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "CAPI_CRD_WAIT_ENABLED='0'") &&
      strcontains(base64decode(f.content), "GENESIS_APPLY_MANIFESTS=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a worker must never be handed the CAPI-install/CRD-wait work, even with genesis_apply_manifests populated"
  }
}

run "set_hostname_true_default_includes_hostname_and_fqdn" {
  command = plan

  variables {
    node_role           = "server-init"
    cluster_token       = "SUPERSECRETTOKEN123"
    cluster_agent_token = "SUPERSECRETAGENT456"
    cluster_fqdn_suffix = "test.example"
  }

  assert {
    condition     = yamldecode(output.cloud_init_user_data).hostname == "test-cp-0"
    error_message = "set_hostname defaults to true — hostname must be written, preserving today's behavior for every existing caller"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).fqdn == "test-cp-0.test.example"
    error_message = "set_hostname defaults to true — fqdn must be written when cluster_fqdn_suffix is set"
  }
}

run "set_hostname_false_omits_hostname_and_fqdn" {
  command = plan

  variables {
    node_role           = "server-init"
    cluster_token       = "SUPERSECRETTOKEN123"
    cluster_agent_token = "SUPERSECRETAGENT456"
    cluster_fqdn_suffix = "test.example"
    set_hostname        = false
  }

  assert {
    condition     = !contains(keys(yamldecode(output.cloud_init_user_data)), "hostname")
    error_message = "set_hostname = false must omit hostname entirely — a shared cloud-init payload (e.g. a CAPI MachineDeployment's replicas) cannot carry a node-unique hostname"
  }
  assert {
    condition     = !contains(keys(yamldecode(output.cloud_init_user_data)), "fqdn")
    error_message = "set_hostname = false must omit fqdn entirely, even when cluster_fqdn_suffix is set"
  }
}
