# SPDX-License-Identifier: Apache-2.0
ACTIVE=0
for _ in $(seq 1 60); do
  if systemctl is-active --quiet rke2-agent; then
    ACTIVE=1
    break
  fi
  sleep 5
done
if [ "$ACTIVE" -ne 1 ]; then
  echo "kube-compute: rke2-agent did not become active within 300s" >&2
  exit 1
fi
