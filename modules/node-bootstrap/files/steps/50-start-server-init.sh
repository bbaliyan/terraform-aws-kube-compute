# SPDX-License-Identifier: Apache-2.0
if [ "$NODE_ROLE" = "server-init" ]; then
  systemctl enable --now rke2-server.service
fi
