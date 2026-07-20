#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
SIGNING_KEY="${SIGNING_KEY:?SIGNING_KEY is required}"
USIGN_BIN="${USIGN_BIN:-usign}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT")}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-synthetic-next.XXXXXX")"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

cp -R "$ROOT_DIR/." "$WORK/source"
printf '0.7.12\n' > "$WORK/source/luci-vpn-ui/VERSION"
printf '0.7.12\n' > "$WORK/source/luci-vpn-ui/files/usr/share/vpn-ui/version"
rewrite() {
  expression="$1" file="$2" temporary="$2.synthetic-new"
  sed "$expression" "$file" > "$temporary"
  chmod 755 "$temporary"
  mv "$temporary" "$file"
}
rewrite 's/\[ "$APP_VERSION" = "0\.7\.11" \]/[ "$APP_VERSION" = "0.7.12" ]/' \
  "$WORK/source/scripts/build-openwrt-ipks.sh"
rewrite 's/\[ "$APP_VERSION" = 0\.7\.11 \]/[ "$APP_VERSION" = 0.7.12 ]/' \
  "$WORK/source/scripts/stage-router-release.sh"

SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  RELEASE_PUBLIC_KEY="$ROOT_DIR/release/keys/router-ui-production.pub" \
  RELEASE_KEY_ID="$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.key-id")" \
  USIGN_BIN="$USIGN_BIN" BUILD_DIR="$WORK/build" OUT_DIR="$WORK/ipk" FEED_DIR="$WORK/feed" \
  "$WORK/source/scripts/build-openwrt-ipks.sh"

SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  RELEASE_PUBLIC_KEY="$ROOT_DIR/release/keys/router-ui-production.pub" \
  RELEASE_KEY_ID="$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.key-id")" \
  USIGN_BIN="$USIGN_BIN" SIGNING_KEY="$SIGNING_KEY" IPK_DIR="$WORK/ipk" \
  OUT_ROOT="$WORK/output" RELEASE_DIR="$OUTPUT_DIR" \
  "$WORK/source/scripts/stage-router-release.sh"

[ "$(sed -n '1p' "$OUTPUT_DIR/vpn-ui-version.txt")" = 0.7.12 ]
jq -e '.app_version == "0.7.12" and .package_version == "0.7.12-1" and
  .release_tag == "vpn-panel-v0.7.12" and .source_dirty == false' \
  "$OUTPUT_DIR/router-release-manifest.json" >/dev/null
"$USIGN_BIN" -q -V -p "$ROOT_DIR/release/keys/router-ui-production.pub" \
  -m "$OUTPUT_DIR/router-release-manifest.json" \
  -x "$OUTPUT_DIR/router-release-manifest.json.sig"

printf 'Synthetic production-key-signed target staged at %s\n' "$OUTPUT_DIR"
