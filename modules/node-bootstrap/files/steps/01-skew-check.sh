# SPDX-License-Identifier: Apache-2.0
# Stops the boot when the minor version (x.y) of the image's RKE2 is newer than the
# minor version of $1 (a version such as v1.37.1+rke2r1). A newer patch of the same
# minor is fine. $2 names where $1 came from.
check_rke2_skew() {
  local image image_minor target_minor newest
  image="$(rke2 --version | awk 'NR == 1 {print $3}')"
  image_minor="${image#v}"
  image_minor="${image_minor%%+*}"
  image_minor="${image_minor%.*}"
  target_minor="${1#v}"
  target_minor="${target_minor%%+*}"
  target_minor="${target_minor%.*}"
  newest="$(printf '%s\n%s\n' "$target_minor" "$image_minor" | sort -V | tail -n 1)"
  if [ "$image_minor" != "$target_minor" ] && [ "$newest" = "$image_minor" ]; then
    echo "kube-compute: the image has RKE2 $image, which is newer than $1 from $2" >&2
    exit 1
  fi
}
