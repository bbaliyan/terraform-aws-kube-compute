# SPDX-License-Identifier: Apache-2.0
# Rejoin detection. RKE2 has no --cluster-init flag: the first server is simply the one
# whose config has no "server:" key. A REPLACED genesis node must rejoin an already-healthy
# cluster rather than re-initializing etcd, which would split-brain a live quorum.
# Each probe entry is an IP or a name. A name is resolved on the node, and every IP it gives
# is probed in turn except this node's own. The first IP that answers is the join target, so
# one peer being down or replaced in the same apply does not hide the live cluster. 200, 401
# and 403 all mean "the API server is up and answering". The pass repeats for about 60
# seconds, so a slow DNS answer or a booting peer cannot start a second etcd.
# If nothing answers, there is no cluster to rejoin, so this really is genesis.
JOIN_TARGET=""
PROBE_DEADLINE=$(($(date +%s) + 60))
while [ -z "$JOIN_TARGET" ]; do
  for PROBE_ENTRY in $REJOIN_PROBE_ADDRESSES; do
    for PROBE_ADDRESS in $(getent ahostsv4 "$PROBE_ENTRY" | awk '$2 == "STREAM" {print $1}'); do
      [ "$PROBE_ADDRESS" = "$NODE_IP" ] && continue
      PROBE_CODE="$(curl -sk --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' "https://$PROBE_ADDRESS:6443/readyz" || true)"
      case "$PROBE_CODE" in
        200|401|403)
          JOIN_TARGET="$PROBE_ADDRESS"
          # The cluster already exists, so this node is a joining server from here on.
          # The genesis steps key on server-init and must not run against a live cluster.
          NODE_ROLE=server-join
          break 3
          ;;
      esac
    done
  done
  if [ "$(date +%s)" -ge "$PROBE_DEADLINE" ]; then break; fi
  sleep 5
done
if [ -z "$JOIN_TARGET" ]; then
  echo "kube-compute: no rejoin probe address answered ($REJOIN_PROBE_ADDRESSES); initializing a new cluster" >&2
fi
