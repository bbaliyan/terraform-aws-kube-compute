# SPDX-License-Identifier: Apache-2.0
# Regression test for a real production bug: the platform Application's
# rendered valuesObject must nest EVERY line of platform_helm_values_object/
# extra_tags under spec.sources[0].helm.valuesObject, not just the first key.
#
# `indent(10, yamlencode(local.platform_values_object))` in main.tf only
# accounted for valuesObject's own column (the template's literal leading
# whitespace already places yamlencode's first line correctly) — every
# continuation line landed 4 columns short of where it needed to be, spilling
# nested keys out as siblings of helm/valuesObject itself. Kubernetes'
# server-side schema validation then rejected the Application outright:
# "unknown field spec.sources[0].helm.billing-code" and
# "unknown field spec.sources[0].traefikExtraConfig" — the exact shape hit on
# a real cluster (extra_tags = {"billing-code" = ...} plus a nested
# platform_helm_values_object with ports.*.port-style structure). Fixed to
# indent(14, ...), matching the interpolation's own 14-space leading
# whitespace so yamlencode's 0-based nesting re-bases onto the template's
# actual column instead of an arbitrary shorter one.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
}

run "platform_app_valuesobject_nests_every_line_correctly" {
  command = plan

  variables {
    node_role                = "server-init"
    cluster_token            = "SUPERSECRETTOKEN123"
    cluster_agent_token      = "SUPERSECRETAGENT456"
    gitops_platform_repo_url = "https://example.test/platform.git"
    extra_tags               = { "billing-code" = "TEST-123" }
    platform_helm_values_object = {
      traefikExtraConfig = {
        ports = {
          bootstrap = {
            port     = 25555
            protocol = "TCP"
          }
        }
      }
    }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      can(yamldecode(base64decode(f.content)).spec.sources[0].helm.valuesObject.extraTags["billing-code"]) &&
      yamldecode(base64decode(f.content)).spec.sources[0].helm.valuesObject.extraTags["billing-code"] == "TEST-123"
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "extra_tags must render nested under spec.sources[0].helm.valuesObject.extraTags — the exact 'unknown field spec.sources[0].helm.billing-code' bug this guards against"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      can(yamldecode(base64decode(f.content)).spec.sources[0].helm.valuesObject.traefikExtraConfig.ports.bootstrap.port) &&
      yamldecode(base64decode(f.content)).spec.sources[0].helm.valuesObject.traefikExtraConfig.ports.bootstrap.port == 25555
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "a deeply nested platform_helm_values_object entry must render nested under spec.sources[0].helm.valuesObject — the exact 'unknown field spec.sources[0].traefikExtraConfig' bug this guards against"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !can(yamldecode(base64decode(f.content)).spec.sources[0].traefikExtraConfig) &&
      !can(yamldecode(base64decode(f.content)).spec.sources[0].helm["billing-code"])
      if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ])
    error_message = "traefikExtraConfig/billing-code must not appear at the wrong nesting level (spec.sources[0].traefikExtraConfig or spec.sources[0].helm.billing-code)"
  }
}
