# SPDX-License-Identifier: Apache-2.0
# RKE2 only applies what it finds under server/manifests at startup, so the file must exist
# before the first start. Cilium is cluster-wide state, so a joining server does not apply
# it. It is a render from the platform ref, never RKE2's HelmChart CRD: that CR's finalizer
# runs `helm uninstall` on deletion, which would fight handing off to Argo CD.
if [ "$NODE_ROLE" = "server-init" ]; then
  install -d -m 0700 /var/lib/rancher/rke2/server/manifests
  install -m 0600 "$PLATFORM_DIR/bootstrap/rendered/cilium.yaml" /var/lib/rancher/rke2/server/manifests/cilium.yaml
fi
