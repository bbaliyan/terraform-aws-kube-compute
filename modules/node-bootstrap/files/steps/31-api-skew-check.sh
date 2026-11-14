# SPDX-License-Identifier: Apache-2.0
if [ "$NODE_ROLE" = "server-join" ]; then
  # Cheap check: /version answers without credentials. It is skipped when the API
  # server does not answer.
  API_HOST="${JOIN_TARGET:-$REGISTRATION_ADDRESS}"
  API_VERSION="$(curl -sk --connect-timeout 3 --max-time 10 "https://$API_HOST:6443/version" | awk -F'"' '$2 == "gitVersion" {print $4}' || true)"
  if [ -n "$API_VERSION" ]; then
    check_rke2_skew "$API_VERSION" "the API server"
  fi
fi
