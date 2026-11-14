# SPDX-License-Identifier: Apache-2.0
# The platform Application tells kube-platform where the workloads repo is, so
# the bootstrap chart can read a values file from it. With no workloads repo
# the Application must render exactly as before, with no workloads parameters.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
}

run "no_workloads_repo_adds_no_parameters" {
  command = plan

  variables {
    gitops_workloads_repo_url = null
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "workloadsRepoURL") &&
      !strcontains(base64decode(f.content), "workloadsRevision") &&
      !strcontains(base64decode(f.content), "workloadsPath")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "without a workloads repo the platform Application must carry no workloads parameters"
  }
}

run "workloads_repo_adds_three_parameters" {
  command = plan

  variables {
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_revision = "release"
    gitops_workloads_path     = "apps"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      contains(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters, { name = "workloadsRepoURL", value = "https://example.test/workloads.git" }) &&
      contains(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters, { name = "workloadsRevision", value = "release" }) &&
      contains(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters, { name = "workloadsPath", value = "apps" })
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "with a workloads repo the platform Application must carry workloadsRepoURL, workloadsRevision and workloadsPath from the gitops_workloads_* inputs"
  }
}
