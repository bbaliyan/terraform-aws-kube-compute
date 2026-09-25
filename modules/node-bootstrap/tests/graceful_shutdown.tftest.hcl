# SPDX-License-Identifier: Apache-2.0
# Graceful node shutdown lives in three places that have to agree: the kubelet drop-in that
# sets the grace period, the config.yaml.d fragment that points kubelet at that drop-in, and
# the logind override that lets kubelet hold the shutdown open for that long. Any one of them
# missing leaves the feature silently doing nothing, so each is asserted on its own.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
  node_role    = "server-init"
}

run "the_default_writes_all_three_files" {
  command = plan

  assert {
    condition = length(setsubtract(
      ["/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf", "/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml", "/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf"],
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
    )) == 0
    error_message = "the kubelet drop-in, the config-dir fragment and the logind override must all be written"
  }
}

run "the_grace_period_reaches_kubelet" {
  command = plan

  variables {
    graceful_shutdown = { seconds = 120, critical_seconds = 45 }
  }

  assert {
    condition = strcontains(
      base64decode(one([for f in yamldecode(output.cloud_init_user_data).write_files : f.content if f.path == "/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf"])),
      "shutdownGracePeriod: 120s",
    )
    error_message = "seconds must render as the kubelet shutdownGracePeriod"
  }

  assert {
    condition = strcontains(
      base64decode(one([for f in yamldecode(output.cloud_init_user_data).write_files : f.content if f.path == "/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf"])),
      "shutdownGracePeriodCriticalPods: 45s",
    )
    error_message = "critical_seconds must render as the kubelet shutdownGracePeriodCriticalPods"
  }

  assert {
    condition = strcontains(
      base64decode(one([for f in yamldecode(output.cloud_init_user_data).write_files : f.content if f.path == "/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf"])),
      "InhibitDelayMaxSec=125",
    )
    error_message = "logind must allow longer than the grace period, or it caps kubelet to its own 5s default and the eviction never finishes"
  }
}

run "kubelet_is_pointed_at_the_drop_in_directory" {
  command = plan

  assert {
    condition = strcontains(
      base64decode(one([for f in yamldecode(output.cloud_init_user_data).write_files : f.content if f.path == "/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml"])),
      "config-dir=/etc/rancher/rke2/kubelet.conf.d",
    )
    error_message = "shutdownGracePeriod has no kubelet flag, so the drop-in is only read when kubelet is given config-dir"
  }
}

run "logind_is_reloaded_before_rke2_starts" {
  command = plan

  assert {
    condition     = contains(yamldecode(output.cloud_init_user_data).runcmd, ["systemctl", "restart", "systemd-logind"])
    error_message = "the logind override only takes effect once logind is restarted"
  }

  assert {
    condition = (
      index(yamldecode(output.cloud_init_user_data).runcmd, ["systemctl", "restart", "systemd-logind"])
      < index(yamldecode(output.cloud_init_user_data).runcmd, ["/opt/kube-compute/bootstrap.sh"])
    )
    error_message = "logind must be restarted before the node joins, or the first shutdown is still capped at 5s"
  }
}

run "null_leaves_the_node_untouched" {
  command = plan

  variables {
    graceful_shutdown = null
  }

  assert {
    condition = length(setintersection(
      ["/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf", "/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml", "/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf"],
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
    )) == 0
    error_message = "null must write none of the three files"
  }

  assert {
    condition     = !contains(yamldecode(output.cloud_init_user_data).runcmd, ["systemctl", "restart", "systemd-logind"])
    error_message = "null must not restart logind either"
  }
}
