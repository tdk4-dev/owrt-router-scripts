#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/dist}"
RELEASE_DIR="${OUT_DIR:-$OUT_ROOT/release-v$APP_VERSION}"

# The legacy-named tar is a transport adapter only. The canonical IPKs must
# already exist; scripts/stage-router-release.sh embeds those exact bytes and
# never copies application files independently into the bundle.
[ "$APP_VERSION" = 0.7.11 ] || {
  printf 'Legacy compatibility transport is permanently scoped to the 0.7.11 bridge.\n' >&2
  exit 1
}
OUT_ROOT="$OUT_ROOT" RELEASE_DIR="$RELEASE_DIR" \
  "$ROOT_DIR/scripts/stage-router-release.sh"

printf 'Legacy compatibility transport: %s/luci-vpn-ui.tar.gz\n' "$RELEASE_DIR"
