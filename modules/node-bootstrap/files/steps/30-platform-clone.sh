# SPDX-License-Identifier: Apache-2.0
# Genesis only, and after the rejoin probe: a node that became a joining server reads
# nothing from the platform ref. Host networking works before the CNI exists.
# git has no retry of its own, so the caller loops. A 40-digit hex revision is a commit:
# a shallow clone by branch or tag cannot fetch it.
clone_platform() {
  rm -rf "$PLATFORM_DIR"
  if [[ "$PLATFORM_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    git clone -q --filter=blob:none --no-checkout "$PLATFORM_REPO_URL" "$PLATFORM_DIR" &&
      git -C "$PLATFORM_DIR" checkout -q "$PLATFORM_REVISION"
  else
    git clone -q --depth 1 --branch "$PLATFORM_REVISION" "$PLATFORM_REPO_URL" "$PLATFORM_DIR"
  fi
}
require_platform_file() {
  if [ ! -s "$PLATFORM_DIR/$1" ]; then
    echo "kube-compute: $PLATFORM_REPO_URL at $PLATFORM_REVISION has no $1" >&2
    exit 1
  fi
}
if [ "$NODE_ROLE" = "server-init" ]; then
  # GIT_TERMINAL_PROMPT=0 makes a private repo fail instead of waiting for a password.
  export GIT_TERMINAL_PROMPT=0
  PLATFORM_CLONED=0
  for _ in 1 2 3 4 5; do
    if clone_platform; then
      PLATFORM_CLONED=1
      break
    fi
    sleep 5
  done
  if [ "$PLATFORM_CLONED" -ne 1 ]; then
    echo "kube-compute: could not clone $PLATFORM_REPO_URL at $PLATFORM_REVISION" >&2
    exit 1
  fi
  for required_file in $PLATFORM_REQUIRED_FILES; do
    require_platform_file "$required_file"
  done
  PLATFORM_K8S_VERSION="$(awk '$1 == "k8sVersion:" {print $2}' "$PLATFORM_DIR/platform/platform-versions/values.yaml")"
  if [ -z "$PLATFORM_K8S_VERSION" ]; then
    echo "kube-compute: $PLATFORM_REPO_URL at $PLATFORM_REVISION has no k8sVersion in platform/platform-versions/values.yaml" >&2
    exit 1
  fi
  check_rke2_skew "$PLATFORM_K8S_VERSION" "$PLATFORM_REPO_URL at $PLATFORM_REVISION"
fi
