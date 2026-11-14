# SPDX-License-Identifier: Apache-2.0
# Waits for readiness, so the bootstrap log reflects real success or failure and not
# "service started" alone.
READY=0
for _ in $(seq 1 60); do
  if $KUBECTL get node "$(hostname)" --no-headers 2>/dev/null | awk '{print $2}' | grep -qE '^Ready'; then
    READY=1
    break
  fi
  sleep 5
done
if [ "$READY" -ne 1 ]; then
  echo "kube-compute: node did not report Ready within 300s" >&2
  exit 1
fi
echo "kube-compute: node Ready $(date -Is)"
