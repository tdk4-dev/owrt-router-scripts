#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
ROUTER_UI_SIGNING_KEY="${ROUTER_UI_SIGNING_KEY:?ROUTER_UI_SIGNING_KEY is required}"
ROUTER_UI_SIGNING_KEY_ID="${ROUTER_UI_SIGNING_KEY_ID:?ROUTER_UI_SIGNING_KEY_ID is required}"
USIGN_BIN="${USIGN_BIN:-usign}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT")}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-synthetic-next.XXXXXX")"
export ROUTER_UI_SIGNING_KEY ROUTER_UI_SIGNING_KEY_ID USIGN_BIN

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

cp -R "$ROOT_DIR/." "$WORK/source"
printf '0.7.11\n' > "$WORK/source/luci-vpn-ui/VERSION"
printf '0.7.11-1\n' > "$WORK/source/luci-vpn-ui/PACKAGE_VERSION"
printf '0.7.11\n' > "$WORK/source/luci-vpn-ui/files/usr/share/vpn-ui/version"

SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  USIGN_BIN="$USIGN_BIN" BUILD_DIR="$WORK/build" OUT_DIR="$WORK/ipk" FEED_DIR="$WORK/feed" \
  ROUTER_UI_DISPOSABLE_TEST_MARKER=0.7.11-final-test \
  "$WORK/source/scripts/build-openwrt-ipks.sh"

SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false USIGN_BIN="$USIGN_BIN" IPK_DIR="$WORK/ipk" \
  FEED_DIR="$WORK/feed" "$WORK/source/scripts/sign-opkg-feed.sh"
SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  USIGN_BIN="$USIGN_BIN" IPK_DIR="$WORK/ipk" OUT_DIR="$WORK/installed-set" \
  "$WORK/source/scripts/stage-installed-package-set.sh"

SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  USIGN_BIN="$USIGN_BIN" IPK_DIR="$WORK/ipk" FEED_DIR="$WORK/feed" \
  INSTALLED_SET_DIR="$WORK/installed-set" RELEASE_CHANNEL=stable \
  OUT_ROOT="$WORK/output" RELEASE_DIR="$OUTPUT_DIR" \
  "$WORK/source/scripts/stage-router-release.sh"

[ "$(sed -n '1p' "$OUTPUT_DIR/vpn-ui-version.txt")" = 0.7.11 ]
jq -e '.app_version == "0.7.11" and .package_version == "0.7.11-1" and
  .release_tag == "vpn-panel-v0.7.11" and .channel == "stable" and .source_dirty == false' \
  "$OUTPUT_DIR/router-release-manifest.json" >/dev/null
tar -xzOf "$OUTPUT_DIR/premier-router-core_0.7.11-1_all.ipk" ./data.tar.gz |
  tar -xzOf - ./usr/share/premier-router/disposable-test-marker |
  grep -Fqx 0.7.11-final-test
"$WORK/source/scripts/verify-release-signature.sh" "$ROUTER_UI_SIGNING_KEY_ID" \
  "$OUTPUT_DIR/router-release-manifest.json" "$OUTPUT_DIR/router-release-manifest.json.sig"

printf 'Synthetic stable 0.7.11 target staged at %s\n' "$OUTPUT_DIR"
