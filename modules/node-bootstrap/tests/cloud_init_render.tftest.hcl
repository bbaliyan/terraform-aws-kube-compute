# SPDX-License-Identifier: Apache-2.0
# Guards the lean-cloud-init contract: the payload must be a single valid
# cloud-config document, must set a distinct hostname, must write and invoke the
# bootstrap program, and must carry the values that program needs -- node.env
# for the flags that gate its genesis-only work, and one config.yaml fragment
# for everything knowable before the node boots. This module renders neither
# the Cilium nor the Argo CD manifest itself (the first server reads both from the
# platform ref) — no `helm`/network dependency for these tests to mock.
#
# What the program DOES with a flag is not assertable here. These tests assert
# the values it is handed, plus that it references every key node.env defines.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
}

run "server_init_payload_is_valid_cloud_config" {
  command = plan

  variables {
    node_role                = "server-init"
    cluster_token            = "SUPERSECRETTOKEN123"
    cluster_agent_token      = "SUPERSECRETAGENT456"
    cluster_fqdn             = "api.test.example"
    cluster_fqdn_suffix      = "test.example"
    extra_tls_sans           = ["*.test.example"]
    gitops_platform_repo_url = "https://example.test/platform.git"
    registration_address     = "api.test.example"
  }

  assert {
    condition     = startswith(output.cloud_init_user_data, "#cloud-config\n")
    error_message = "the payload must start with the #cloud-config marker line or cloud-init ignores it entirely"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).hostname == "test-cp-0"
    error_message = "the payload must set the OS hostname — RKE2/kubelet default the registered Kubernetes node name to it, so a missing or colliding hostname silently clobbers another node's registration"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).fqdn == "test-cp-0.test.example"
    error_message = "cluster_fqdn_suffix must produce a matching cloud-init fqdn"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).prefer_fqdn_over_hostname == false
    error_message = "prefer_fqdn_over_hostname must be false — RHEL-family cloud-init otherwise silently applies fqdn as the real system hostname even though a distinct short hostname is also set, which then makes NetworkManager derive a DNS search-domain entry matching the cluster's own wildcard DNS zone"
  }
  assert {
    condition     = contains(yamldecode(output.cloud_init_user_data).runcmd, ["/opt/kube-compute/bootstrap.sh"])
    error_message = "the payload must invoke the bootstrap program from runcmd"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      f.permissions == "0755" && f.encoding == "b64" && base64decode(f.content) == local.bootstrap_program_inline
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "the payload must write the comment-stripped bootstrap program to /opt/kube-compute/bootstrap.sh with mode 0755, so it overwrites any copy an older image bakes"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/node.env"
    )
    error_message = "the payload must deliver node.env — it is how every per-cluster value now reaches the bootstrap program"
  }
  # The drift guard on a contract that is now split across two repos: a key
  # renamed on either side of it silently stops reaching the node, and `set -u`
  # in the program would only catch the half that goes missing there.
  assert {
    condition = alltrue([
      for k in keys(local.node_config_values) :
      strcontains(local.bootstrap_program, k)
    ])
    error_message = "every key node.env defines must be read by the bootstrap program, or the two halves of the boot have drifted apart"
  }
  # The baked cilium.yaml must not outlive the Cilium handoff to Argo CD: RKE2
  # re-applies every server/manifests file on each start. The removal must come
  # after the Cilium wait, inside the genesis-only branch, and appear once.
  assert {
    condition = (
      length(split("rm -f /var/lib/rancher/rke2/server/manifests/cilium.yaml", local.bootstrap_program)) == 2
      && strcontains(split("rm -f /var/lib/rancher/rke2/server/manifests/cilium.yaml", local.bootstrap_program)[0], "rollout status daemonset/cilium -n kube-system")
    )
    error_message = "bootstrap.sh must remove the boot cilium.yaml exactly once, after it waits for the Cilium DaemonSet"
  }
  assert {
    condition = (
      strcontains(local.bootstrap_program, "if [ \"$NODE_ROLE\" = \"server-init\" ]; then\n  # RKE2 re-applies")
      && !strcontains(
        split("rm -f /var/lib/rancher/rke2/server/manifests/cilium.yaml", split("if [ \"$NODE_ROLE\" = \"server-init\" ]; then\n  # RKE2 re-applies", local.bootstrap_program)[1])[0],
        "\nfi\n"
      )
    )
    error_message = "the boot cilium.yaml must be removed only inside the server-init branch, never for a joining server"
  }
  assert {
    condition = !anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "KUBE_BOOTSTRAP_SHA256")
    ])
    error_message = "no image and module pairing remains, so nothing may carry a bootstrap.sh hash"
  }
  assert {
    condition = alltrue([
      for f in yamldecode(output.cloud_init_user_data).write_files : f.encoding == "b64"
    ])
    error_message = "every write_files entry must be base64-encoded — that is what keeps an arbitrary PEM, Helm render, or operator-supplied manifest from breaking the outer cloud-config document"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      f.permissions == "0600" if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "config.yaml must be mode 0600 — it carries the cluster join tokens"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "token: \"SUPERSECRETTOKEN123\"\nagent-token: \"SUPERSECRETAGENT456\"\n")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "a genesis node must carry both tokens in its config.yaml, as JSON strings"
  }
  assert {
    condition     = !contains([for f in yamldecode(output.cloud_init_user_data).write_files : f.path], "/opt/kube-compute/secrets.env")
    error_message = "a server needs no secrets.env: the tokens are in config.yaml"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "\"*.test.example\"")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "a wildcard tls-san must be emitted quoted — '*' is YAML's alias indicator, so an unquoted entry is invalid YAML and RKE2 refuses to start"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "secrets-encryption: true") &&
      strcontains(base64decode(f.content), "disable-cloud-controller: true") &&
      strcontains(base64decode(f.content), "ingress-controller: none")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "the ported config.yaml must keep secrets-encryption, disable-cloud-controller, and ingress-controller: none"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kube-apiserver-memory=1024Mi") &&
      strcontains(base64decode(f.content), "etcd-memory=512Mi")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "the control plane's static pods need memory requests, or the scheduler places pods into the memory kube-apiserver and etcd use"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kube-scheduler-arg:\n  - \"bind-address=0.0.0.0\"") &&
      strcontains(base64decode(f.content), "kube-controller-manager-arg:\n  - \"bind-address=0.0.0.0\"")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "the scheduler and controller manager must listen beyond loopback, or kube-platform's Prometheus can't scrape them and their down alerts fire on every cluster"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "PLATFORM_REQUIRED_FILES='bootstrap/rendered/cilium.yaml bootstrap/rendered/argocd.yaml'") &&
      strcontains(base64decode(f.content), "NODE_ROLE='server-init'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "node.env must carry the role and the platform files the genesis node requires"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/10-platform-app.yaml"
    )
    error_message = "a server-init node with a platform repo must carry the platform Application manifest"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "kubelet-arg")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "with dns_servers unset, no kubelet-arg resolv-conf override should be emitted at all"
  }
}

# Regression test for a real bug hit on a live apply: kubelet's default
# ClusterFirst DNS policy copies the node's own /etc/resolv.conf search
# domains into every pod. This node's own search domain (NetworkManager-
# derived from its FQDN, cluster_fqdn_suffix) collides with the wildcard
# cluster DNS record for that same zone — with a pod's default ndots:5, a
# bare external hostname like "github.com" gets that search suffix tried
# first, silently resolving to the cluster's own wildcard IP. A clone of
# github.com then fails with connection refused.
run "dns_servers_set_gives_kubelet_a_search_domain_free_resolv_conf" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    cluster_fqdn              = "api.test.example"
    cluster_fqdn_suffix       = "test.example"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    dns_servers               = ["1.1.1.1", "9.9.9.9"]
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      base64decode(f.content) == "nameserver 1.1.1.1\nnameserver 9.9.9.9\n"
      if f.path == "/etc/rancher/rke2/resolv-conf-no-search.conf"
    ])
    error_message = "the kubelet resolv-conf override file must contain exactly the given nameservers, no search domain"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kubelet-arg:") &&
      strcontains(base64decode(f.content), "resolv-conf=/etc/rancher/rke2/resolv-conf-no-search.conf")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "config.yaml must point kubelet at the search-domain-free resolv-conf override"
  }
}

run "worker_payload_skips_genesis_only_content" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    node_labels               = { "topology.kubernetes.io/zone" = "eu-west-1a" }
  }

  # A worker's program has no genesis step at all, and its server URL is in config.yaml.
  assert {
    condition     = !anytrue([for name in output.boot_steps : startswith(name, "genesis-")])
    error_message = "a worker's boot program must hold no genesis step"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "server: https://10.0.0.10:9345\n")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "a worker's config.yaml must name the server it joins"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "NODE_ROLE='worker'") &&
      strcontains(base64decode(f.content), "PLATFORM_REQUIRED_FILES=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a worker must be handed none of the genesis-only work: no Argo CD bootstrap, and a role the program gates the Cilium apply on"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "REGISTRATION_ADDRESS='10.0.0.10'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a worker must be told where to join — the program builds its server URL from this"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "topology.kubernetes.io/zone=eu-west-1a")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "a worker's config.yaml fragment must carry its node labels"
  }
  assert {
    condition = alltrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "kube-scheduler-arg")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "control-plane arguments belong to servers only; a worker runs no scheduler"
  }
}

run "provider_steps_run_before_the_boot_program" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    provider_steps            = [{ name = "provider-one", commands = [["/bin/sh", "-c", "echo one"]] }]
    provider_files            = [{ path = "/etc/provider-one", content = "one\n", permissions = "0600" }]
  }

  assert {
    condition = (
      yamldecode(output.cloud_init_user_data).runcmd[0] == ["/bin/sh", "-c", "echo one"] &&
      index(yamldecode(output.cloud_init_user_data).runcmd, ["/opt/kube-compute/bootstrap.sh"]) > 0
    )
    error_message = "a provider step must run first, before the module's commands and the boot program"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      base64decode(f.content) == "one\n" && f.permissions == "0600"
      if f.path == "/etc/provider-one"
    ])
    error_message = "a provider file must be written with the given content and mode"
  }
  assert {
    condition     = output.boot_steps[0] == "provider-one"
    error_message = "boot_steps must start with the provider steps"
  }
}

run "provider_step_names_must_be_unique" {
  command = plan

  variables {
    node_role = "worker"
    provider_steps = [
      { name = "same", commands = [] },
      { name = "same", commands = [] },
    ]
  }

  expect_failures = [var.provider_steps]
}

run "no_provider_logic_in_the_module" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
  }

  assert {
    condition     = !anytrue([for c in yamldecode(output.cloud_init_user_data).runcmd : strcontains(join(" ", c), "169.254.169.254") || strcontains(join(" ", c), "ssm") || strcontains(join(" ", c), "iscsid") || strcontains(join(" ", c), "nsupdate")])
    error_message = "without provider steps the module must run no AWS or Proxmox command"
  }
}

run "kubelet_reserves_resources_for_the_node_before_rke2_starts" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
  }

  assert {
    condition = (
      strcontains(yamldecode(output.cloud_init_user_data).runcmd[0][2], "kube-reserved=cpu=%sm,memory=%sMi") &&
      strcontains(yamldecode(output.cloud_init_user_data).runcmd[0][2], "system-reserved=cpu=100m,memory=256Mi")
    )
    error_message = "kubelet must reserve CPU and memory for itself, containerd and the OS, or pods can take the whole node and it drops out of the cluster"
  }
  assert {
    condition     = strcontains(yamldecode(output.cloud_init_user_data).runcmd[0][2], "p = 11 * 110 + 255")
    error_message = "kube-reserved memory must be capped by the per-pod formula, or large nodes reserve memory kubelet and containerd never use"
  }
  assert {
    condition     = strcontains(yamldecode(output.cloud_init_user_data).runcmd[0][2], "eviction-hard=memory.available<100Mi,nodefs.available<10%%,imagefs.available<15%%,nodefs.inodesFree<5%%,imagefs.inodesFree<5%%")
    error_message = "eviction-hard replaces every default threshold, so the disk and inode ones must be restated alongside memory"
  }
}

run "server_join_uses_the_staggered_self_healing_join" {
  command = plan

  variables {
    node_role            = "server-join"
    node_name            = "test-cp-1"
    registration_address = "10.0.0.10"
    cluster_token        = "SUPERSECRETTOKEN123"
  }

  # The staggered self-healing join loop lives in the bootstrap program, gated on
  # this one value; what a joining server must not inherit is genesis work.
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "NODE_ROLE='server-join'") &&
      strcontains(base64decode(f.content), "PLATFORM_REQUIRED_FILES=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a joining server must be marked as one — the program keys its staggered self-healing join, and its skip of the genesis Cilium and Argo CD applies, on the role"
  }
  assert {
    condition     = strcontains(local.bootstrap_program, "join-race exhausted after 6 attempts")
    error_message = "the bootstrap program must keep the self-healing join retry loop — etcd admits one non-voting learner at a time, so a concurrent join must wipe local server state and retry"
  }
}

run "registry_mirror_pins_containerd_tls_to_the_trusted_ca" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    registry_mirror_url       = "https://mirror.test"
    trusted_ca_pem            = "-----BEGIN CERTIFICATE-----\nZHVtbXk=\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "\"mirror.test\":") &&
      strcontains(base64decode(f.content), "ca_file: /etc/pki/ca-trust/source/anchors/trusted-ca.crt")
      if f.path == "/etc/rancher/rke2/registries.yaml"
    ])
    error_message = "registries.yaml must strip the scheme from the mirror host and pin containerd's TLS verification to the trusted CA anchor"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"
    )
    error_message = "trusted_ca_pem must be written to the OS trust anchors directory"
  }
}

# The AWS path: a server-init node with only registration_address set probes that
# one address, exactly as before the probe list existed.
run "server_init_probes_registration_address_by_default" {
  command = apply
  variables {
    node_role            = "server-init"
    registration_address = "nlb.example.com"
    cluster_token        = "t"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "REJOIN_PROBE_ADDRESSES='nlb.example.com'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a server-init node with no explicit probe list must probe registration_address"
  }
}
