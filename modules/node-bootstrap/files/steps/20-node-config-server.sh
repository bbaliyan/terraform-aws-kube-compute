# SPDX-License-Identifier: Apache-2.0
# Everything in the RKE2 config that is known at plan time is in /etc/rancher/rke2/config.yaml,
# written by cloud-init. This drop-in holds what only the node knows: its own IP and the
# server it found by the rejoin probe. A key that ends in "+" appends to the list in config.yaml.
install -d -m 0755 /etc/rancher/rke2/config.yaml.d
umask 077
{
  echo "node-ip: $NODE_IP"
  echo "tls-san+:"
  echo "  - \"$NODE_IP\""
  if [ -n "${JOIN_TARGET:-}" ]; then echo "server: https://$JOIN_TARGET:9345"; fi
} >/etc/rancher/rke2/config.yaml.d/20-node.yaml
umask 022
