#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'image-build:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

# Compatibility entrypoint. All targets use the same generic builder and the
# exact prebuilt canonical project IPKs.
TARGET_DIR="${TARGET_DIR:-x86/64}" \
PROFILE="${PROFILE:-generic}" \
ARTIFACT_PREFIX="${ARTIFACT_PREFIX:-}" \
  exec "$ROOT_DIR/build-openwrt-custom-image-linux.sh"
