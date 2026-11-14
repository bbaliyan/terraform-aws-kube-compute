#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runtime half of the RKE2 bootstrap. The image bakes the OS, the RKE2 binaries and the
# tools. This program holds what only this node can do: join logic and the genesis steps.
#
# Terraform joins the step files in this directory that apply to the node's role, and
# cloud-init writes the result to /opt/kube-compute/bootstrap.sh with its comment lines
# removed to save space. A step that does not apply to the role is never in the file.
# Per-cluster values reach the program as data, in node.env. A heredoc body in a step
# must never start with "#", because the comment strip would remove that line.

set -euo pipefail
exec > >(tee -a /var/log/kube-compute-bootstrap.log) 2>&1
echo "kube-compute: bootstrap start $(date -Is)"

# A cloud-init command that failed before this program leaves this marker, because
# runcmd does not stop at a failed command. Stop here, so the boot fails.
if [ -e /run/kube-compute-step-failed ]; then
  echo "kube-compute: a step before the boot program failed; see /var/log/cloud-init-output.log" >&2
  exit 1
fi
rm -f /run/kube-compute-boot-complete

MISSING_TOOLS=""
for tool in git curl getent ip awk systemctl; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
  echo "kube-compute: the image lacks these tools:$MISSING_TOOLS" >&2
  exit 1
fi

KC=/opt/kube-compute
# shellcheck disable=SC1091
. "$KC/node.env"

# containerd's TLS pin in registries.yaml points at this file, so a node without the CA
# cannot pull images. cloud-init writes the file, or the image bakes it.
if [ -n "$TRUSTED_CA_FILE" ]; then
  if [ ! -s "$TRUSTED_CA_FILE" ]; then
    echo "kube-compute: no trusted CA at $TRUSTED_CA_FILE" >&2
    exit 1
  fi
  command -v update-ca-trust >/dev/null 2>&1 || { echo "kube-compute: the image lacks update-ca-trust" >&2; exit 1; }
fi

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
PLATFORM_DIR=/run/platform-ref

# RKE2 needs the node's own IP for node-ip and, on a server, for tls-san.
NODE_IP="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
if [ -z "$NODE_IP" ]; then
  echo "kube-compute: could not determine this node's IP" >&2
  exit 1
fi
