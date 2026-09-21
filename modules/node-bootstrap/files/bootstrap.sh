#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runtime half of the RKE2 bootstrap: everything the node image deliberately
# does NOT bake, because it is per-cluster identity, per-cluster secrets, or
# join logic that only makes sense once this specific node boots. The bake-time
# half (OS prep, RKE2 binaries, SELinux policy, guest agent, kernel modules) is
# already present in the image.
#
# THIS FILE IS BAKED INTO THE IMAGE, not delivered by cloud-init. It is a plain
# program with no templating: every per-cluster value reaches it as data, in
# node.env (configuration) and secrets.env (tokens), both written by cloud-init.
# It used to be rendered per node by Terraform's templatefile() and shipped in
# user data, which cost ~9.6 KB there and again inside every worker group's
# cloud-init in a CAPI bundle. EC2 allows 16384 decoded bytes of user data for
# everything a node boots with, and three copies of this program did not fit.
# Baking it is also what the images already do with the Cilium and Argo CD
# renders, for the same reason on Proxmox, whose snippet cap is 1 MiB.
#
# The contract between this file and the module that writes node.env is the
# integer below. Bump it whenever a key is added, removed, or changes meaning,
# and the module's node_env_contract must move with it: a mismatched pair fails
# on the next line rather than half-configuring a node. An image NEWER than the
# module needs no version check -- an older module ships its own rendered copy
# of this file in write_files, which simply overwrites the baked one.
BOOTSTRAP_CONTRACT=1

set -euo pipefail
exec > >(tee -a /var/log/kube-compute-bootstrap.log) 2>&1
echo "kube-compute: bootstrap start $(date -Is)"

KC=/opt/kube-compute
# shellcheck disable=SC1091
. "$KC/node.env"
# shellcheck disable=SC1091
. "$KC/secrets.env"

if [ "${KUBE_COMPUTE_CONTRACT:-unset}" != "$BOOTSTRAP_CONTRACT" ]; then
  echo "kube-compute: this image bakes bootstrap contract $BOOTSTRAP_CONTRACT but node.env was written for contract ${KUBE_COMPUTE_CONTRACT:-unset} -- the image and the kube-compute module version are not a matching pair, so rebuild the image or move the module pin" >&2
  exit 1
fi

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

# Polls for something the platform Application installs. On a dedicated control
# plane that first needs a worker to join and run Argo CD, hence the long ceiling.
PLATFORM_WAIT_SECONDS=1800
wait_until() {
  local what=$1 deadline=$((SECONDS + PLATFORM_WAIT_SECONDS))
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "kube-compute: gave up after ${PLATFORM_WAIT_SECONDS}s waiting for $what" >&2
      return 1
    fi
    sleep 5
  done
}

cert_manager_webhook_has_endpoints() {
  [ -n "$($KUBECTL get endpoints cert-manager-webhook -n cert-manager -o jsonpath='{.subsets}' 2>/dev/null)" ]
}

# Own IP, discovered on the node itself — the same probe the Ansible role's
# dns-self-register task used. RKE2 needs it for node-ip and (on a server) as
# the first tls-san entry.
NODE_IP="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
if [ -z "$NODE_IP" ]; then
  echo "kube-compute: could not determine this node's IP" >&2
  exit 1
fi

TRUSTED_CA_PATH=/etc/pki/ca-trust/source/anchors/trusted-ca.crt
if [ "$TRUSTED_CA_ENABLED" = "1" ]; then
  # Written by cloud-init or baked into the image. registries.yaml pins
  # containerd's TLS to this file, so a node without it cannot pull images.
  if [ ! -s "$TRUSTED_CA_PATH" ]; then
    echo "kube-compute: no trusted CA at $TRUSTED_CA_PATH -- either this module was told the image bakes one (trusted_ca_in_image) and it does not, or cloud-init failed to write it" >&2
    exit 1
  fi
  update-ca-trust extract
fi

if [ "$NODE_ROLE" = "server-init" ] && [ -n "$DNS_SELF_REGISTER_ZONE" ]; then
  # Publishes a single-target A record as soon as this node knows its own IP, so
  # a concurrently-bootstrapping sibling never has to wait for the round-robin
  # api.* record every control-plane node contributes to.
  if ! command -v nsupdate >/dev/null 2>&1; then
    dnf install -y bind-utils
  fi
  # A TSIG keyfile (rather than nsupdate's -y "<alg>:<name>:<secret>" form) keeps
  # the secret out of /proc/<pid>/cmdline, readable by any local user for the
  # lifetime of the process. Written 0600 via umask, removed unconditionally
  # afterwards whether or not the update itself succeeded.
  umask 077
  cat >/run/dns-self-register-tsig.key <<EOF
key "$TSIG_KEY_NAME" {
  algorithm $TSIG_KEY_ALGORITHM;
  secret "${TSIG_KEY_SECRET:-}";
};
EOF
  trap 'rm -f /run/dns-self-register-tsig.key' EXIT
  # NSUPDATE_FLAGS is deliberately unquoted: it is a flag list that must word-split.
  # shellcheck disable=SC2086
  nsupdate $NSUPDATE_FLAGS -k /run/dns-self-register-tsig.key <<EOF
server $DNS_SERVER_ADDRESS $DNS_SERVER_PORT
zone $DNS_SELF_REGISTER_ZONE
update delete $DNS_SELF_REGISTER_RECORD_NAME.$DNS_SELF_REGISTER_ZONE A
update add $DNS_SELF_REGISTER_RECORD_NAME.$DNS_SELF_REGISTER_ZONE $DNS_SELF_REGISTER_TTL A $NODE_IP
send
EOF
  rm -f /run/dns-self-register-tsig.key
  trap - EXIT
  umask 022
fi

if [ "$ISCSI_INITIATOR_ENABLED" = "1" ]; then
  # Replaces the OS-generated random InitiatorName (iscsi-initiator-utils writes
  # one on first boot) with a deterministic one derived from this node's own
  # identity, so the target-side initiator allow-list can be registered once,
  # ahead of time, instead of re-discovered and re-registered by hand after
  # every VM rebuild.
  cat >/etc/iscsi/initiatorname.iscsi <<EOF
InitiatorName=iqn.2026.lan.$CLUSTER_NAME:$ISCSI_INITIATOR_LABEL
EOF
  systemctl restart iscsid
fi

if [ -n "$REGISTRY_MIRROR_URL" ]; then
  # Advisory only, matching the Ansible role's uri check in spirit: a 200 or 401
  # both mean "the mirror is answering". Non-fatal here because a first boot must
  # not be lost to a transiently unreachable mirror.
  MIRROR_CODE="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$REGISTRY_MIRROR_URL/v2/" || true)"
  case "$MIRROR_CODE" in
    200|401) echo "kube-compute: registry mirror preflight OK ($MIRROR_CODE)" ;;
    *) echo "kube-compute: registry mirror preflight did not answer 200/401 (got '$MIRROR_CODE'), continuing" >&2 ;;
  esac
fi

install -d -m 0755 /etc/rancher/rke2
CONFIG=/etc/rancher/rke2/config.yaml
# Everything in config.yaml that is known before this node boots — labels,
# taints, extra SANs, the server flags, kubelet's resolv-conf pointer — arrives
# as this one fragment, in the order config.yaml needs it. The module decides
# its content per role; this script only appends it to the lines that can be
# known nowhere but here.
CONFIG_STATIC="$KC/rke2-config-static.yaml"
umask 077
if [ "$NODE_ROLE" = "worker" ]; then
  # The fetch command is provider-shaped: on Proxmox it is a literal `echo
  # '<token>'` (no secret store to fetch from), on AWS an SSM call. Either way it
  # is evaluated here, never embedded in config.yaml as a command.
  RESOLVED_AGENT_TOKEN="$(eval "${AGENT_TOKEN_FETCH_COMMAND:-}")"
  if [ -z "$RESOLVED_AGENT_TOKEN" ]; then
    echo "kube-compute: agent_token_fetch_command produced an empty token" >&2
    exit 1
  fi
  {
    echo "server: https://$REGISTRATION_ADDRESS:9345"
    echo "token: $RESOLVED_AGENT_TOKEN"
    echo "node-ip: $NODE_IP"
    cat "$CONFIG_STATIC"
  } >"$CONFIG"
else
  SERVER_LINE=""
  if [ "$NODE_ROLE" = "server-join" ]; then
    # An additional control-plane node is always joining an existing cluster.
    SERVER_LINE="server: https://$REGISTRATION_ADDRESS:9345"
  fi
  if [ "$NODE_ROLE" = "server-init" ] && [ -n "$REGISTRATION_ADDRESS" ]; then
    # Rejoin detection. RKE2 has no --cluster-init flag: the first server is simply
    # the one whose config.yaml has no "server:" key. A REPLACED genesis node must
    # rejoin an already-healthy cluster rather than blindly re-initializing etcd,
    # which would split-brain a live quorum. 200/401/403 all mean "the API server
    # is up and answering"; anything else (including no answer at all) means there
    # is no cluster to rejoin, so this really is genesis.
    PROBE_CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "https://$REGISTRATION_ADDRESS:6443/readyz" || true)"
    case "$PROBE_CODE" in
      200|401|403) SERVER_LINE="server: https://$REGISTRATION_ADDRESS:9345" ;;
    esac
  fi
  {
    if [ -n "$SERVER_LINE" ]; then echo "$SERVER_LINE"; fi
    echo "token: ${CLUSTER_TOKEN:-}"
    # Empty on a server-join node, exactly as the Ansible template rendered it
    # there (the env lookup produced ""); RKE2 tolerates the empty value and the
    # genesis node's agent-token is the one that actually governs agent joins.
    echo "agent-token: ${CLUSTER_AGENT_TOKEN:-}"
    echo "node-ip: $NODE_IP"
    echo "tls-san:"
    # Quote every SAN: a wildcard entry (e.g. *.cluster.example) starts with '*',
    # which is YAML's alias indicator, so an unquoted "- *.foo" is invalid YAML
    # and RKE2 refuses to start. Quoting is inert for plain IPs/hostnames. The
    # module quotes the entries it contributes to CONFIG_STATIC for the same reason.
    echo "  - \"$NODE_IP\""
    cat "$CONFIG_STATIC"
  } >"$CONFIG"
fi
chmod 0600 "$CONFIG"
umask 022

if [ "$NODE_ROLE" != "worker" ]; then
  # ---- auto-deploy manifests: must exist before RKE2's first start, since RKE2
  #      only applies whatever it finds under server/manifests/ at startup ----
  install -d -m 0700 /var/lib/rancher/rke2/server/manifests
  if [ "$CNI" = "cilium" ] && [ "$NODE_ROLE" = "server-init" ]; then
    # Genesis only: Cilium is cluster-wide state, not per-node, so a joining server
    # does not re-apply it. Rendered by `helm template` on the operator, never via
    # RKE2's HelmChart CRD — that CR's finalizer runs `helm uninstall` on deletion,
    # which would fight handing off to Argo CD.
    install -m 0600 "$KC/manifests/cilium.yaml" /var/lib/rancher/rke2/server/manifests/cilium.yaml
  fi
  if [ -d "$KC/server-manifests" ]; then
    for extra_manifest in "$KC/server-manifests/"*; do
      if [ -e "$extra_manifest" ]; then
        install -m 0600 "$extra_manifest" /var/lib/rancher/rke2/server/manifests/
      fi
    done
  fi
fi

if [ "$NODE_ROLE" = "server-init" ]; then
  systemctl enable --now rke2-server.service
fi
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
if [ "$NODE_ROLE" = "worker" ]; then
  systemctl enable --now rke2-agent.service
fi

# ---- wait for readiness, so the bootstrap log reflects real success/failure
#      rather than "service started" alone ----
if [ "$NODE_ROLE" != "worker" ]; then
  READY=0
  for attempt in $(seq 1 60); do
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
else
  ACTIVE=0
  for attempt in $(seq 1 60); do
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
fi

if [ "$ARGOCD_NEEDED" = "1" ]; then
  # ---- GitOps/Argo CD bootstrap: genesis only, after the node is Ready ----
  # Node Ready only means the CNI is minimally configured — not that CoreDNS
  # itself is up and its ClusterIP is actually routable yet. Applying Argo CD's
  # manifest immediately races its own pods (which resolve each other by
  # ClusterIP DNS, e.g. dex-server -> argocd-repo-server) against CoreDNS/
  # Cilium's own startup: confirmed on a real apply, argocd-dex-server crashed
  # ("no route to host" dialing CoreDNS's ClusterIP) 22s after Cilium reported
  # Ready, because CoreDNS's own pod wasn't Ready yet. It self-heals via
  # Kubernetes' restart backoff, but that backoff is pure wasted time before
  # the cluster settles — waiting here instead is a bounded few seconds against
  # an already-scheduled pod, not a new dependency.
  #
  # A loop, not a single `kubectl wait`: RKE2 installs CoreDNS asynchronously
  # via its own helm-install job, so the pod frequently doesn't exist yet at
  # this point in boot — `kubectl wait` errors immediately ("no matching
  # resources found") rather than waiting for a resource to be *created*, and
  # under `set -e` that silently killed the rest of this script on a real
  # apply. Non-fatal on timeout (falls through and applies Argo CD anyway):
  # this is a speedup, not a hard dependency — Argo CD's own restart/selfHeal
  # already covers the case where CoreDNS is unusually slow.
  #
  # k8s-app=kube-dns, not a name guess: RKE2's CoreDNS chart labels its pod
  # with the standard upstream convention, not chart/release-name-derived.
  COREDNS_READY=0
  for attempt in $(seq 1 60); do
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
  # --server-side is required: a client-side apply stores the previous config in
  # a last-applied-configuration annotation, and Argo CD's applicationsets CRD
  # exceeds Kubernetes' 262144-byte annotation limit.
  $KUBECTL apply --server-side -f "$KC/manifests/00-argocd.yaml"
  # NOT a health wait — only blocks until the API server serves the Application
  # type (avoids a "no matches for kind Application" race). Deliberately does not
  # wait for argocd-server to roll out: on a tainted control plane, or before a
  # worker pool joins, it has nowhere to schedule yet and converges once capacity
  # exists.
  $KUBECTL wait --for=condition=established --timeout=120s crd/applications.argoproj.io
  if [ "$PLATFORM_APP_ENABLED" = "1" ] || [ "$WORKLOADS_APP_ENABLED" = "1" ]; then
    # condition=established above only proves the CRD *type* exists — not that
    # argocd-application-controller has started reconciling yet. It's what
    # creates the built-in "default" AppProject on its own startup, and an
    # Application applied before that exists fails with a transient
    # InvalidSpecError ("referencing project default which does not exist"),
    # confirmed on a real apply.
    #
    # The controller alone is not enough either: an Application whose first
    # comparison finds repo-server or redis not yet serving (redis waits on the
    # argocd-redis-secret-init Job, and the pods that need its Secret restart
    # once) reports sync status Unknown and is not compared again until the
    # next reconciliation, which cost two idle minutes on a real apply. The
    # workloads already exist at this point, so rollout status waits on their
    # pods rather than erroring on a missing resource.
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

if [ "$CAPI_CRD_WAIT_ENABLED" = "1" ]; then
  # ---- CAPI/CAPMOX install + genesis-apply entries: genesis only, after the
  #      node is Ready, and deliberately AFTER the Argo CD block above (not
  #      before, as an earlier revision had it). clusterctl's generated
  #      CAPI-core/CAPMOX manifests provision their webhook TLS via
  #      cert-manager Issuer/Certificate objects (cert-manager.io/v1) — a hard
  #      dependency, not cosmetic — and cert-manager itself is only installed
  #      by the platform Argo CD Application applied just above (kube-platform's
  #      wave-0 cert-manager-app.yaml). Applying capi-install.yaml before that
  #      exists fails outright ("no matches for kind Issuer/Certificate in
  #      version cert-manager.io/v1: ensure CRDs are installed first"),
  #      confirmed on a real apply. The composing module (proxmox-cluster) is
  #      expected to enforce cluster_autoscaler_enabled requires
  #      gitops_platform_enabled via its own precondition — this block does not
  #      re-check that, it only waits for the dependency that precondition
  #      guarantees will eventually appear.
  #
  #      CRDs existing is NOT sufficient, though — confirmed on a second real
  #      apply after the CRD-wait alone was in place: cert-manager's chart
  #      installs the CRDs and starts the webhook Deployment in the same Helm
  #      release, so the CRD-established/controller-not-ready race that
  #      already bit the machinedeployments CRD wait below applies just as
  #      much to cert-manager's own *validating* webhook — Issuer/Certificate
  #      is gated by ValidatingWebhookConfiguration "webhook.cert-manager.io"
  #      at admission time, and that failed with "no endpoints available for
  #      service cert-manager-webhook" when the webhook Pod hadn't finished
  #      starting yet, even though the CRDs themselves already existed. Wait
  #      for the Service to actually have endpoints (a Pod passed its
  #      readiness probe and got registered), not just for the CRD type to
  #      exist. This script does not interpret GENESIS_APPLY_MANIFESTS'
  #      content — the composing module decides what goes in the list; this is
  #      just the ordered apply. ----
  wait_until "cert-manager CRDs" $KUBECTL get crd certificates.cert-manager.io issuers.cert-manager.io || exit 1
  wait_until "cert-manager-webhook endpoints" cert_manager_webhook_has_endpoints || exit 1
  if [ "$CAPI_INSTALL_BAKED" = "1" ]; then
    $KUBECTL apply -f "$KC/manifests/capi-install.yaml"
    # Wait for CAPI's core CRDs to be Established before applying anything that
    # references them — same "CRD-established vs controller-running" race this
    # project already hit and fixed for Argo CD's own bootstrap (see the
    # CoreDNS-wait / argocd-application-controller-wait loops above).
    for attempt in $(seq 1 60); do
      if $KUBECTL get crd machinedeployments.cluster.x-k8s.io >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
  else
    # No baked capi-install.yaml on this image: Cluster API arrives as a platform
    # Argo CD Application, so this waits rather than installs. The wait is far
    # longer than the baked case because Argo CD has to sync the operator, the
    # operator has to reconcile the providers, and every one of those pulls images.
    wait_until "Cluster API CRDs" $KUBECTL get crd machinedeployments.cluster.x-k8s.io || exit 1
  fi
fi

# Not nested inside the CAPI_CRD_WAIT_ENABLED block above: the genesis-apply
# list is a generic mechanism, not autoscaler-specific, so its own apply must
# not silently depend on that flag being set too — a caller passing manifests
# with the wait flag left false would otherwise get them written to disk
# (write_files runs unconditionally) but never applied, with no error anywhere.
# Unquoted on purpose: this is a space-separated list that must word-split.
# shellcheck disable=SC2086
for manifest_path in $GENESIS_APPLY_MANIFESTS; do
  wait_until "$manifest_path to apply" $KUBECTL apply -f "$manifest_path" || { $KUBECTL apply -f "$manifest_path"; exit 1; }
done

echo "kube-compute: bootstrap complete $(date -Is)"
