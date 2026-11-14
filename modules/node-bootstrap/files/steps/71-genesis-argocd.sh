# SPDX-License-Identifier: Apache-2.0
if [ "$NODE_ROLE" = "server-init" ]; then
  # Genesis only, after the node is Ready. Node Ready only means the CNI is minimally
  # configured, not that CoreDNS is up and its ClusterIP is routable. Applying Argo CD
  # at once races its own pods (which resolve each other by ClusterIP DNS) against
  # CoreDNS and Cilium startup: argocd-dex-server can crash with "no route to host"
  # dialing CoreDNS. It self-heals through restart backoff, but that is wasted time.
  #
  # A loop, not a single `kubectl wait`: RKE2 installs CoreDNS asynchronously, so the
  # pod often does not exist yet, and `kubectl wait` errors at once on a missing
  # resource, which under `set -e` would end this script. Non-fatal on timeout: it is
  # a speedup, and Argo CD's own selfHeal covers a slow CoreDNS.
  #
  # k8s-app=kube-dns, not a name guess: RKE2's CoreDNS chart labels its pod with the
  # upstream convention.
  COREDNS_READY=0
  for _ in $(seq 1 60); do
    if $KUBECTL wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=5s >/dev/null 2>&1; then
      COREDNS_READY=1
      break
    fi
    sleep 2
  done
  if [ "$COREDNS_READY" -ne 1 ]; then
    echo "kube-compute: CoreDNS did not report Ready within ~150s, proceeding anyway" >&2
  else
    echo "kube-compute: CoreDNS Ready $(date -Is)"
  fi
  # The manifest comes from the platform ref cloned before RKE2 started. Failing here is
  # fatal: a node without Argo CD never syncs.
  # --server-side is required: a client-side apply stores the previous config in
  # a last-applied-configuration annotation, and Argo CD's applicationsets CRD
  # exceeds Kubernetes' 262144-byte annotation limit. --force-conflicts takes
  # ownership of fields from an earlier partial apply on a retried boot.
  $KUBECTL apply --server-side --force-conflicts -f "$PLATFORM_DIR/bootstrap/rendered/argocd.yaml"
  # NOT a health wait: it only blocks until the API server serves the Application
  # type, which avoids a "no matches for kind Application" race. It does not wait for
  # argocd-server to roll out: on a tainted control plane, or before a worker pool
  # joins, that has nowhere to schedule yet and converges once capacity exists.
  $KUBECTL wait --for=condition=established --timeout=120s crd/applications.argoproj.io
  if [ "$PLATFORM_APP_ENABLED" = "1" ] || [ "$WORKLOADS_APP_ENABLED" = "1" ]; then
    # condition=established proves only that the CRD type exists, not that
    # argocd-application-controller is reconciling. It creates the built-in "default"
    # AppProject on startup, and an Application applied before that fails with a
    # transient InvalidSpecError.
    #
    # The controller alone is not enough: an Application whose first comparison finds
    # repo-server or redis not yet serving reports sync status Unknown and is not
    # compared again until the next reconciliation, about two idle minutes later. The
    # workloads already exist at this point, so rollout status waits on their pods.
    for workload in statefulset/argocd-application-controller deployment/argocd-repo-server deployment/argocd-redis; do
      if ! $KUBECTL rollout status "$workload" -n argocd --timeout=150s >/dev/null; then
        echo "kube-compute: $workload did not become ready within 150s, proceeding anyway" >&2
      fi
    done
    echo "kube-compute: Argo CD ready $(date -Is)"
  fi
  if [ "$PLATFORM_APP_ENABLED" = "1" ]; then
    $KUBECTL apply -f "$KC/manifests/10-platform-app.yaml"
  fi
  if [ "$WORKLOADS_APP_ENABLED" = "1" ]; then
    $KUBECTL apply -f "$KC/manifests/11-workloads-app.yaml"
  fi
fi
