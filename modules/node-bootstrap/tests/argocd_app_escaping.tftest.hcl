# SPDX-License-Identifier: Apache-2.0
# Every caller-supplied string reaches the Argo CD Applications unchanged,
# whatever YAML syntax it contains, and adds no keys of its own. Values that a
# YAML parser would read as another type (true, 1.0, null, an octal-looking
# number) must stay strings, because Helm parameters and revisions are strings.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"

  gitops_workloads_repo_url = "https://example.test/workloads.git"
  gitops_workloads_revision = "1.0"
  gitops_workloads_path     = "apps #not-a-comment"

  platform_extra_helm_parameters = {
    "quote"      = "say \"hi\""
    "backslash"  = "C:\\path\\to\\file"
    "colon"      = "key: value"
    "newline"    = "first line\nsecond: line\n  - item"
    "injection"  = "x\"\n            - name: injected\n              value: \"y"
    "flow"       = "{a: 1, b: [2, 3]}"
    "anchor"     = "*alias &anchor !tag"
    "bool"       = "true"
    "number"     = "0644"
    "null"       = "null"
    "empty"      = ""
    "name: with" = "a colon in the name"
  }
  workloads_extra_helm_parameters = {
    "quote"     = "say \"hi\""
    "backslash" = "C:\\path\\to\\file"
    "colon"     = "key: value"
    "newline"   = "first line\nsecond: line"
    "injection" = "x\"\n              - name: injected\n                value: \"y"
  }
}

run "platform_helm_parameters_round_trip" {
  command = plan

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files : alltrue([
        for name, val in var.platform_extra_helm_parameters :
        contains(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters, { name = name, value = val })
      ])
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "every platform_extra_helm_parameters entry must decode to the exact name and value the caller passed"
  }

  # 9 built-in parameters come before the extras: the 6 that every platform
  # Application carries, and the 3 workloads* ones that a workloads repo adds.
  # A test assertion cannot read another run's output, so the count is written out.
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      length(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters) == 9 + length(var.platform_extra_helm_parameters) &&
      !contains([for p in yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters : p.name], "injected")
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "a parameter value must not add parameters of its own"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      contains(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters, { name = "workloadsRevision", value = "1.0" }) &&
      contains(yamldecode(base64decode(f.content)).spec.sources[0].helm.parameters, { name = "workloadsPath", value = "apps #not-a-comment" })
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "the workloads parameters must decode to the exact gitops_workloads_* strings"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      keys(yamldecode(base64decode(f.content))) == ["apiVersion", "kind", "metadata", "spec"] &&
      keys(yamldecode(base64decode(f.content)).spec) == ["destination", "project", "sources", "syncPolicy"]
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "a parameter value must not add keys to the platform Application"
  }
}

run "workloads_source_round_trips" {
  command = plan

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      yamldecode(base64decode(f.content)).spec.source.helm.parameters == [
        for name, val in var.workloads_extra_helm_parameters : { name = name, value = val }
      ]
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "the workloads parameters must decode to exactly the entries the caller passed, and no others"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      yamldecode(base64decode(f.content)).spec.source.targetRevision == "1.0" &&
      yamldecode(base64decode(f.content)).spec.source.path == "apps #not-a-comment" &&
      keys(yamldecode(base64decode(f.content)).spec.source) == ["helm", "path", "repoURL", "targetRevision"]
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "the workloads source must carry the revision and path as exact strings and no extra keys"
  }
}
