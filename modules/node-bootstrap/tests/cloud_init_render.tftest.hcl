# SPDX-License-Identifier: Apache-2.0
# Guards the lean-cloud-init contract: the payload must be a single valid
# cloud-config document, must set a distinct hostname, must invoke the baked
# bootstrap program, and must carry the values that program needs -- node.env
# for the flags that gate its genesis-only work, and one config.yaml fragment
# for everything knowable before the node boots. This module renders neither
# the Cilium nor the Argo CD manifest itself (the image bakes both) — no
# `helm`/network dependency for these tests to mock.
#
# What the program DOES with a flag is not assertable here: the program is a
# baked file, not part of the payload. These tests assert the values it is
# handed, plus that it references every key node.env defines.

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
    condition     = yamldecode(output.cloud_init_user_data).runcmd[2] == ["/opt/kube-compute/bootstrap.sh"]
    error_message = "the payload must invoke the baked bootstrap program from runcmd"
  }
  assert {
    condition     = strcontains(yamldecode(output.cloud_init_user_data).runcmd[1][2], "bakes no /opt/kube-compute/bootstrap.sh")
    error_message = "runcmd must first check the program is actually baked into this image — without it an image predating the bake fails with cloud-init's own bare 'No such file or directory' against a path this module used to write itself"
  }
  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/bootstrap.sh"
    )
    error_message = "the program must NOT travel in user data -- shipping it is what put this payload over EC2's 16384-byte limit, once here and once more inside every worker group's cloud-init"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/node.env"
    )
    error_message = "the payload must deliver node.env — it is how every per-cluster value now reaches the baked program"
  }
  # The drift guard on a contract that is now split across two repos: a key
  # renamed on either side of it silently stops reaching the node, and `set -u`
  # in the program would only catch the half that goes missing there.
  assert {
    condition = alltrue([
      for k in keys(local.node_config_values) :
      strcontains(local.bootstrap_program, k)
    ])
    error_message = "every key node.env defines must be read by the baked program, or the two halves of the boot have drifted apart"
  }
  assert {
    condition     = strcontains(local.bootstrap_program, "BOOTSTRAP_CONTRACT=${local.node_env_contract}")
    error_message = "the baked program's contract number must match node_env_contract — the program refuses to run against any other, so a bump on one side alone fails every node's boot"
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
      f.permissions == "0600" if f.path == "/opt/kube-compute/secrets.env"
    ])
    error_message = "secrets.env must be mode 0600 — it carries the cluster join tokens and the TSIG secret"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "\"*.test.example\"")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "a wildcard tls-san must be emitted quoted — '*' is YAML's alias indicator, so an unquoted entry is invalid YAML and RKE2 refuses to start"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "secrets-encryption: true") &&
      strcontains(base64decode(f.content), "disable-cloud-controller: true") &&
      strcontains(base64decode(f.content), "ingress-controller: none")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "the ported config.yaml must keep secrets-encryption, disable-cloud-controller, and ingress-controller: none"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kube-apiserver-memory=1024Mi") &&
      strcontains(base64decode(f.content), "etcd-memory=512Mi")
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "the control plane's static pods need memory requests, or the scheduler places pods into the memory kube-apiserver and etcd use"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "CNI='cilium'") &&
      strcontains(base64decode(f.content), "NODE_ROLE='server-init'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "node.env must carry the two values that gate the genesis Cilium apply: the CNI and the role"
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
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
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
# first, silently resolving to the cluster's own wildcard IP. Confirmed on
# cluster-1: Argo CD's repo-server tried to git-clone github.com against the
# node's own IP over HTTPS and got connection refused.
run "dns_servers_set_gives_kubelet_a_search_domain_free_resolv_conf" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    cluster_fqdn              = "api.test.example"
    cluster_fqdn_suffix       = "test.example"
    gitops_platform_enabled   = false
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
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
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

  # A worker is denied the genesis work by the flags it is given, not by a
  # different program: the same baked file boots every role.
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "NODE_ROLE='worker'") &&
      strcontains(base64decode(f.content), "ARGOCD_NEEDED='0'") &&
      strcontains(base64decode(f.content), "CAPI_CRD_WAIT_ENABLED='0'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a worker must be handed none of the genesis-only work: no Argo CD bootstrap, no CAPI wait, and a role the program gates the Cilium apply on"
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
      if f.path == "/opt/kube-compute/rke2-config-static.yaml"
    ])
    error_message = "a worker's config.yaml fragment must carry its node labels"
  }
}

run "aws_provider_id_is_set_before_rke2_starts" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    aws_provider_id           = true
  }

  assert {
    condition = (
      strcontains(yamldecode(output.cloud_init_user_data).runcmd[0][2], "provider-id=aws:///%s/%s") &&
      yamldecode(output.cloud_init_user_data).runcmd[3] == ["/opt/kube-compute/bootstrap.sh"]
    )
    error_message = "the providerID drop-in must be written before the bootstrap program starts RKE2, or the node registers without one and cluster-autoscaler cannot match it to its instance"
  }
  assert {
    condition     = strcontains(yamldecode(output.cloud_init_user_data).runcmd[0][2], "node-label+:\\n  - \"node.kubernetes.io/instance-type=%s\"")
    error_message = "the drop-in must label the node with its instance type, which no controller here sets"
  }
}

run "no_aws_provider_id_by_default" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
  }

  assert {
    condition     = length(yamldecode(output.cloud_init_user_data).runcmd) == 3
    error_message = "without aws_provider_id no instance metadata may be read, since outside AWS there is none"
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

  # The staggered self-healing join loop lives in the baked program, gated on
  # this one value; what a joining server must not inherit is genesis work.
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "NODE_ROLE='server-join'") &&
      strcontains(base64decode(f.content), "ARGOCD_NEEDED='0'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a joining server must be marked as one — the program keys its staggered self-healing join, and its skip of the genesis Cilium and Argo CD applies, on the role"
  }
  assert {
    condition     = strcontains(local.bootstrap_program, "join-race exhausted after 6 attempts")
    error_message = "the baked program must keep the self-healing join retry loop — etcd admits one non-voting learner at a time, so a concurrent join must wipe local server state and retry"
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
