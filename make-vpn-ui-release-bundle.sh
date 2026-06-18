#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vpn-ui-release.XXXXXX")"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

[ -n "$VERSION" ] || {
  printf 'VERSION is empty\n' >&2
  exit 1
}

mkdir -p "$OUT_DIR" "$STAGE/luci-vpn-ui"
cp -R "$ROOT_DIR/luci-vpn-ui/." "$STAGE/luci-vpn-ui/"
rm -f "$STAGE/luci-vpn-ui.zip"

tar -C "$STAGE" -czf "$OUT_DIR/luci-vpn-ui.tar.gz" luci-vpn-ui
if command -v sha256sum >/dev/null 2>&1; then
  (
    cd "$OUT_DIR"
    sha256sum luci-vpn-ui.tar.gz > luci-vpn-ui.tar.gz.sha256
  )
else
  shasum -a 256 "$OUT_DIR/luci-vpn-ui.tar.gz" |
    awk '{ print $1 "  luci-vpn-ui.tar.gz" }' > "$OUT_DIR/luci-vpn-ui.tar.gz.sha256"
fi
printf '%s\n' "$VERSION" > "$OUT_DIR/vpn-ui-version.txt"

printf 'Release bundle: %s\n' "$OUT_DIR/luci-vpn-ui.tar.gz"
printf 'Version: %s\n' "$VERSION"
