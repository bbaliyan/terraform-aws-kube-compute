# SPDX-License-Identifier: Apache-2.0
# workloads_extra_helm_parameters lets a caller pass a workload chart's
# per-cluster identity (region, FQDN, bucket name, ...) as Helm parameters on
# the rendered workloads Application, instead of that chart's own repo
# hand-typing (and drifting) the same values. workloads_helm_values_object
# carries what a map(string) cannot: a pod's tolerations, an affinity block.
# Covers: a dotted parameter name reaches the nested value Helm's --set syntax
# implies, both inputs render together, and the helm block is omitted entirely
# when neither is set (no dangling `helm:` key).

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
}

run "workloads_app_helm_parameters_render_nested_and_flat" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_path     = "cluster-db"
    workloads_extra_helm_parameters = {
      "backup.bucketName" = "acme-backups-us-east-1"
      "clusterFqdnSuffix" = "cluster-db.us-east-1.example.net"
    }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      can(yamldecode(base64decode(f.content)).spec.source.helm.parameters) &&
      anytrue([
        for p in yamldecode(base64decode(f.content)).spec.source.helm.parameters :
        p.name == "backup.bucketName" && p.value == "acme-backups-us-east-1"
      ])
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "a dotted workloads_extra_helm_parameters key must render verbatim as a name: under spec.source.helm.parameters"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      anytrue([
        for p in yamldecode(base64decode(f.content)).spec.source.helm.parameters :
        p.name == "clusterFqdnSuffix" && p.value == "cluster-db.us-east-1.example.net"
      ])
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "every workloads_extra_helm_parameters entry must render, not just the first"
  }
}

run "workloads_app_omits_helm_block_when_no_extra_parameters" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_path     = "cluster-db"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !can(yamldecode(base64decode(f.content)).spec.source.helm)
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "spec.source.helm must be absent entirely when workloads_extra_helm_parameters is empty (the default) — no dangling 'helm:' key"
  }
}

run "workloads_app_values_object_carries_nested_structures" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_path     = "cluster-db"
    workloads_extra_helm_parameters = {
      "cluster.name" = "test"
    }
    workloads_helm_values_object = {
      placement = {
        nodeSelector = { workload = "reserved" }
        tolerations = [
          { key = "workload", operator = "Equal", value = "reserved", effect = "NoSchedule" },
        ]
      }
    }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      yamldecode(base64decode(f.content)).spec.source.helm.valuesObject.placement.tolerations[0].key == "workload" &&
      yamldecode(base64decode(f.content)).spec.source.helm.valuesObject.placement.nodeSelector.workload == "reserved"
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "a list of objects must survive into spec.source.helm.valuesObject -- that shape is the reason this input exists alongside the map(string) one"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      anytrue([
        for p in yamldecode(base64decode(f.content)).spec.source.helm.parameters :
        p.name == "cluster.name" && p.value == "test"
      ])
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "parameters and valuesObject must render together; setting one must not drop the other"
  }
}

run "workloads_app_values_object_alone_renders_no_parameters_key" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_path     = "cluster-db"
    workloads_helm_values_object = {
      placement = { nodeSelector = { workload = "reserved" } }
    }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      can(yamldecode(base64decode(f.content)).spec.source.helm.valuesObject) &&
      !can(yamldecode(base64decode(f.content)).spec.source.helm.parameters)
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "an empty parameters map must leave no 'parameters:' key behind, which Argo CD rejects as a null list"
  }
}
