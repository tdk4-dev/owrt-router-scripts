#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${RELEASE_ROOT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
GH_BIN="${GH_BIN:-gh}"
VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
TAG="${GITHUB_REF_NAME:-${1:-}}"
TITLE="Router UI ${VERSION}"

ASSETS=(
  "$ROOT_DIR/dist/luci-vpn-ui.tar.gz"
  "$ROOT_DIR/dist/luci-vpn-ui.tar.gz.sha256"
  "$ROOT_DIR/dist/vpn-ui-version.txt"
  "$ROOT_DIR/dist/vpn-ui-changelog.txt"
  "$ROOT_DIR/dist/vpn-ui-release-date.txt"
  "$ROOT_DIR/dist/install-router-ui-release.sh"
  "$ROOT_DIR/dist/install-router-ui-release.sh.sha256"
)

[ -n "$VERSION" ] || {
  printf 'VERSION is empty\n' >&2
  exit 1
}

[ -n "$TAG" ] || {
  printf 'release tag is empty\n' >&2
  exit 1
}

[ "$TAG" = "vpn-panel-v${VERSION}" ] || {
  printf 'release tag %s does not match VERSION %s\n' "$TAG" "$VERSION" >&2
  exit 1
}

for asset in "${ASSETS[@]}"; do
  [ -f "$asset" ] || {
    printf 'release asset is missing: %s\n' "$asset" >&2
    exit 1
  }
done

if ! "$GH_BIN" release view "$TAG" >/dev/null 2>&1; then
  "$GH_BIN" release create "$TAG" \
    "${ASSETS[@]}" \
    --title "$TITLE" \
    --notes-file "$ROOT_DIR/luci-vpn-ui/RELEASE_NOTES.md"
  exit 0
fi

published_title="$("$GH_BIN" release view "$TAG" --json name --jq .name)"
[ "$published_title" = "$TITLE" ] || {
  printf 'existing release title mismatch: expected %s, got %s\n' \
    "$TITLE" "$published_title" >&2
  exit 1
}

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpn-ui-published.XXXXXX")"
cleanup() {
  rm -rf "$VERIFY_DIR"
}
trap cleanup EXIT INT TERM

"$GH_BIN" release download "$TAG" --dir "$VERIFY_DIR"
for asset in "${ASSETS[@]}"; do
  published="$VERIFY_DIR/$(basename "$asset")"
  [ -f "$published" ] || {
    printf 'existing release asset is missing: %s\n' "$(basename "$asset")" >&2
    exit 1
  }
  cmp -s "$asset" "$published" || {
    printf 'existing release asset differs: %s\n' "$(basename "$asset")" >&2
    exit 1
  }
done

printf 'Release %s already exists with the expected title and identical assets.\n' "$TAG"
