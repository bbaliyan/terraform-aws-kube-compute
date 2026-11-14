# SPDX-License-Identifier: Apache-2.0
if [ "$NODE_ROLE" = "server-init" ]; then
  # RKE2 re-applies every file under server/manifests on each rke2-server start
  # (the k3s deploy controller starts with force=true). Once the platform has
  # upgraded Cilium, a restart of this server would put the older boot render
  # back. So remove the boot file as soon as Cilium is running. Deleting a
  # manifest file does not delete the resources it created (k3s documents this;
  # the controller deletes resources only for --disable), so Cilium keeps running.
  # If Cilium is not Ready in time, keep the file: RKE2 keeps retrying it.
  CILIUM_READY=0
  for _ in $(seq 1 30); do
    if $KUBECTL rollout status daemonset/cilium -n kube-system --timeout=10s >/dev/null 2>&1; then
      CILIUM_READY=1
      break
    fi
    sleep 2
  done
  if [ "$CILIUM_READY" -eq 1 ]; then
    rm -f /var/lib/rancher/rke2/server/manifests/cilium.yaml
    echo "kube-compute: Cilium Ready, removed the boot cilium.yaml $(date -Is)"
  else
    echo "kube-compute: WARNING: Cilium did not become Ready within ~6 minutes, so the boot cilium.yaml stays in server/manifests and RKE2 re-applies it on every restart" >&2
  fi
fi
