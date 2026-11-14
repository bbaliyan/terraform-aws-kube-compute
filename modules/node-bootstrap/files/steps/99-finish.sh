# SPDX-License-Identifier: Apache-2.0
rm -rf "$PLATFORM_DIR"
# The agent token is in config.yaml.d by now; the fetch command is not needed again.
rm -f "$KC/secrets.env"
touch /run/kube-compute-boot-complete
echo "kube-compute: bootstrap complete $(date -Is)"
