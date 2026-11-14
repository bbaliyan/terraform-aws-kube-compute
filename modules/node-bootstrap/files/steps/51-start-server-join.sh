# SPDX-License-Identifier: Apache-2.0
if [ "$NODE_ROLE" = "server-join" ]; then
  # Additional control-plane nodes join embedded-etcd one at a time (an upstream
  # etcd limit of one non-voting learner at a time). The real collision guard is
  # the retry loop below — etcd rejects a second concurrent learner outright, and
  # this wipes local server state and retries — so the presleep only needs enough
  # jitter to keep simultaneous starts out of the exact same instant.
  NODE_INDEX="$(hostname | grep -oE '[0-9]+$' || echo 0)"
  sleep $(( (10#$NODE_INDEX * 5) + (RANDOM % 5) ))
  systemctl enable rke2-server.service
  JOIN_ATTEMPT=0
  until systemctl start rke2-server.service && timeout 90 bash -c 'until /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done'; do
    JOIN_ATTEMPT=$((JOIN_ATTEMPT + 1))
    if [ "$JOIN_ATTEMPT" -ge 6 ]; then
      echo "kube-compute: join-race exhausted after 6 attempts" >&2
      exit 1
    fi
    systemctl stop rke2-server 2>/dev/null || true
    rm -rf /var/lib/rancher/rke2/server/tls /var/lib/rancher/rke2/server/cred /var/lib/rancher/rke2/server/db
    sleep 10
  done
fi
