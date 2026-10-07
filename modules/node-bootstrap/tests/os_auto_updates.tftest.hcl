# SPDX-License-Identifier: Apache-2.0

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
  node_role    = "server-init"
}

run "the_default_enables_dnf_automatic_after_bootstrap" {
  command = plan

  assert {
    condition     = contains(yamldecode(output.cloud_init_user_data).runcmd, ["/bin/sh", "-c", local.os_auto_updates_script])
    error_message = "the default must install updates with dnf-automatic"
  }

  assert {
    condition = (
      index(yamldecode(output.cloud_init_user_data).runcmd, ["/bin/sh", "-c", local.os_auto_updates_script])
      > index(yamldecode(output.cloud_init_user_data).runcmd, ["/opt/kube-compute/bootstrap.sh"])
    )
    error_message = "package installs must not hold up the node joining the cluster"
  }
}

run "updates_never_reboot_and_never_touch_rke2" {
  command = plan

  assert {
    condition     = strcontains(local.os_auto_updates_script, "systemctl enable --now dnf-automatic-install.timer")
    error_message = "the install timer applies updates; dnf-automatic's packaged reboot = never stays in force"
  }

  assert {
    condition     = strcontains(local.os_auto_updates_script, "OnBootSec=15min")
    error_message = "a node powered off at the timer's 06:00 must still update after it starts"
  }

  assert {
    condition     = strcontains(local.os_auto_updates_script, "excludepkgs=rke2-server,rke2-agent,rke2-common")
    error_message = "RKE2's packages must be excluded, or dnf upgrades RKE2 outside system-upgrade-controller"
  }

  assert {
    condition     = strcontains(local.os_auto_updates_script, "yum-utils")
    error_message = "needs-restarting comes from yum-utils and is what reports a reboot is due"
  }
}

run "false_leaves_packages_as_baked" {
  command = plan

  variables {
    os_auto_updates = false
  }

  assert {
    condition     = !strcontains(yamlencode(yamldecode(output.cloud_init_user_data).runcmd), "dnf-automatic")
    error_message = "os_auto_updates = false must not install or enable dnf-automatic"
  }
}
