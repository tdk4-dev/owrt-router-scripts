#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE_BUILDER="$ROOT_DIR/build-openwrt-custom-image-linux.sh"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$APP_VERSION-1"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
USIGN_BIN="${USIGN_BIN:-usign}"
SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
SOURCE_DATE_EPOCH=1700000000
KEY_ID=test-release-staging
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/router-release-staging-test.XXXXXX")"
OUT_ROOT="$TMP_DIR/output"
IPK_DIR="$OUT_ROOT/ipk"
RELEASE_DIR="$OUT_ROOT/release-v$APP_VERSION"
SECRET_KEY="$TMP_DIR/release.sec"
PUBLIC_KEY="$TMP_DIR/release.pub"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

command -v "$USIGN_BIN" >/dev/null 2>&1 || {
  printf 'missing usign test dependency\n' >&2
  exit 1
}
"$USIGN_BIN" -G -s "$SECRET_KEY" -p "$PUBLIC_KEY" \
  -c 'Router UI release staging test key'

grep -Fq 'rm -f "$pkg_dir/${pkg}_"*.ipk' "$IMAGE_BUILDER"
grep -Fq 'cp "$PROJECT_PACKAGE_MANIFEST"' "$IMAGE_BUILDER"
grep -Fq 'project-ipk-sha256sums' "$IMAGE_BUILDER"
grep -Fq 'image-provenance.json' "$IMAGE_BUILDER"
grep -Fq 'rm -rf "$TARGET_OUT"' "$IMAGE_BUILDER"

SOURCE_COMMIT="$SOURCE_COMMIT" \
SOURCE_DIRTY=false \
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
RELEASE_PUBLIC_KEY="$PUBLIC_KEY" \
RELEASE_KEY_ID="$KEY_ID" \
BUILD_DIR="$TMP_DIR/build" \
OUT_DIR="$IPK_DIR" \
FEED_DIR="$OUT_ROOT/opkg-feed" \
  "$ROOT_DIR/scripts/build-openwrt-ipks.sh" >"$TMP_DIR/build.log"

OUT_ROOT="$OUT_ROOT" \
IPK_DIR="$IPK_DIR" \
RELEASE_DIR="$RELEASE_DIR" \
SOURCE_COMMIT="$SOURCE_COMMIT" \
SOURCE_DIRTY=false \
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
RELEASE_PUBLIC_KEY="$PUBLIC_KEY" \
RELEASE_KEY_ID="$KEY_ID" \
SIGNING_KEY="$SECRET_KEY" \
USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/stage-router-release.sh" >"$TMP_DIR/stage.log"

RELEASE_DIR="$RELEASE_DIR" \
RELEASE_PUBLIC_KEY="$PUBLIC_KEY" \
EXPECTED_RELEASE_KEY_ID="$KEY_ID" \
EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/validate-staged-release.sh" >"$TMP_DIR/validate.log"

[ -d "$RELEASE_DIR" ]
[ -z "$(find "$RELEASE_DIR" -mindepth 1 -type d -print)" ]
for file in \
  router-release-manifest.json router-release-manifest.json.sig \
  stable-channel.json stable-channel.json.sig \
  release-provenance.json release-provenance.json.sig \
  SHA256SUMS router-ui-packages.txt vpn-ui-version.txt \
  vpn-ui-changelog.txt vpn-ui-release-date.txt \
  router-candidate-validator router-update-supervisor router-update-lib.sh \
  install-router-ui-release.sh install-router-ui-release.sh.sha256 \
  rescue-router-ui.sh rescue-router-ui.sh.sha256 0.7.9-_35_vpn.js
do
  [ -s "$RELEASE_DIR/$file" ] || {
    printf 'missing staged asset: %s\n' "$file" >&2
    exit 1
  }
done

[ "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.ipk' | wc -l | tr -d ' ')" = 3 ]
[ ! -e "$RELEASE_DIR/luci-vpn-ui.tar.gz" ]
for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  [ -s "$RELEASE_DIR/${pkg}_${PKG_VERSION}_all.ipk" ]
  grep -Eq "^$pkg $PKG_VERSION all [0-9a-f]{64} [0-9]+ ${pkg}_${PKG_VERSION}_all.ipk$" \
    "$RELEASE_DIR/router-ui-packages.txt"
done

jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg commit "$SOURCE_COMMIT" --arg key "$KEY_ID" '
  .schema_version == 2 and .update_protocol == 2 and
  .app_version == $version and .package_version == $package and
  .source_commit == $commit and .source_dirty == false and
  .minimum_updater_protocol == 2 and .signing_key_id == $key and
  .transitions == [{"mode":"package-v2","source_protocol":2,"source_version":"0.7.11"}] and
  .compatibility_transport == null and (.images | length) == 0
' "$RELEASE_DIR/router-release-manifest.json" >/dev/null

"$USIGN_BIN" -q -V -p "$PUBLIC_KEY" \
  -m "$RELEASE_DIR/router-release-manifest.json" \
  -x "$RELEASE_DIR/router-release-manifest.json.sig"
"$USIGN_BIN" -q -V -p "$PUBLIC_KEY" \
  -m "$RELEASE_DIR/stable-channel.json" \
  -x "$RELEASE_DIR/stable-channel.json.sig"
"$USIGN_BIN" -q -V -p "$PUBLIC_KEY" \
  -m "$RELEASE_DIR/release-provenance.json" \
  -x "$RELEASE_DIR/release-provenance.json.sig"

mkdir -p "$TMP_DIR/core"
tar -xzOf "$RELEASE_DIR/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -xzf - -C "$TMP_DIR/core"
cmp -s "$TMP_DIR/core/usr/sbin/vpn-ui-update" "$RELEASE_DIR/router-update-supervisor"
cmp -s "$TMP_DIR/core/usr/libexec/premier-router/update-lib.sh" "$RELEASE_DIR/router-update-lib.sh"
cmp -s "$TMP_DIR/core/usr/libexec/premier-router/candidate-validator" "$RELEASE_DIR/router-candidate-validator"
cmp -s "$TMP_DIR/core/usr/sbin/install-router-ui-release" "$RELEASE_DIR/install-router-ui-release.sh"
grep -Fqx "SOURCE_COMMIT=$SOURCE_COMMIT" "$TMP_DIR/core/usr/share/premier-router/build-info"
grep -Fqx 'SOURCE_DIRTY=false' "$TMP_DIR/core/usr/share/premier-router/build-info"
grep -Fqx 'UPDATER_PROTOCOL=2' "$TMP_DIR/core/usr/share/premier-router/build-info"

(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS >"$TMP_DIR/sha256.log"
)

if OUT_ROOT="$OUT_ROOT" IPK_DIR="$IPK_DIR" RELEASE_DIR="$TMP_DIR/strict" \
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  RELEASE_PUBLIC_KEY="$PUBLIC_KEY" RELEASE_KEY_ID="$KEY_ID" SIGNING_KEY="$SECRET_KEY" \
  USIGN_BIN="$USIGN_BIN" STRICT_RELEASE=1 \
    "$ROOT_DIR/scripts/stage-router-release.sh" >"$TMP_DIR/strict.log" 2>&1; then
  printf 'strict staging unexpectedly accepted a development key\n' >&2
  exit 1
fi
grep -q 'strict release refuses a development key ID' "$TMP_DIR/strict.log"

if find "$RELEASE_DIR" -type f | grep -E '/(\.DS_Store|id_rsa|\.env|\.pcap)$'; then
  printf 'release directory contains forbidden local artifacts\n' >&2
  exit 1
fi

printf 'Signed package-first release staging validation passed\n'
