# SPDX-License-Identifier: Apache-2.0
# This drop-in holds what only the node knows: its own IP and the agent token. The fetch
# command is provider-shaped: on Proxmox it is a literal `echo '<token>'`, on AWS an SSM
# call. It is evaluated here and never embedded in the config as a command.
# shellcheck disable=SC1091
. "$KC/secrets.env"
RESOLVED_AGENT_TOKEN="$(eval "${AGENT_TOKEN_FETCH_COMMAND:-}")"
if [ -z "$RESOLVED_AGENT_TOKEN" ]; then
  echo "kube-compute: agent_token_fetch_command produced an empty token" >&2
  exit 1
fi
# A double-quoted YAML scalar: escape the backslash first, then the double quote.
QUOTED_AGENT_TOKEN="${RESOLVED_AGENT_TOKEN//\\/\\\\}"
QUOTED_AGENT_TOKEN="${QUOTED_AGENT_TOKEN//\"/\\\"}"
install -d -m 0755 /etc/rancher/rke2/config.yaml.d
umask 077
{
  echo "node-ip: $NODE_IP"
  echo "token: \"$QUOTED_AGENT_TOKEN\""
} >/etc/rancher/rke2/config.yaml.d/20-node.yaml
umask 022
