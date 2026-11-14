# SPDX-License-Identifier: Apache-2.0
if [ "$NODE_ROLE" = "server-init" ] && [ -d "$KC/server-manifests" ]; then
  install -d -m 0700 /var/lib/rancher/rke2/server/manifests
  for extra_manifest in "$KC/server-manifests/"*; do
    if [ -e "$extra_manifest" ]; then
      install -m 0600 "$extra_manifest" /var/lib/rancher/rke2/server/manifests/
    fi
  done
fi
