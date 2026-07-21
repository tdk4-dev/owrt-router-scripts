#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
USIGN_BIN="${TEST_USIGN_BIN:-$(command -v usign || true)}"
[ -x "$USIGN_BIN" ] || { printf 'usign is required for release-v2 tests\n' >&2; exit 1; }
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-v2-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)"
SECRET="$TMP_ROOT/test.sec"
PUBLIC="$TMP_ROOT/test.pub"
"$USIGN_BIN" -G -s "$SECRET" -p "$PUBLIC" -c 'Router UI protocol v2 ephemeral test key'
KEY_ID="test-$($USIGN_BIN -F -p "$PUBLIC")"

build_once() {
  label="$1"
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    RELEASE_PUBLIC_KEY="$PUBLIC" RELEASE_KEY_ID="$KEY_ID" \
    BUILD_DIR="$TMP_ROOT/build-$label" OUT_DIR="$TMP_ROOT/ipk-$label" \
    FEED_DIR="$TMP_ROOT/feed-$label" "$ROOT_DIR/scripts/build-openwrt-ipks.sh" >/dev/null
}
build_once a
build_once b
diff -u "$TMP_ROOT/ipk-a/router-ui-packages.txt" "$TMP_ROOT/ipk-b/router-ui-packages.txt"
for file in "$TMP_ROOT/ipk-a"/*.ipk; do
  cmp -s "$file" "$TMP_ROOT/ipk-b/$(basename "$file")" || {
    printf 'nondeterministic IPK: %s\n' "$(basename "$file")" >&2
    exit 1
  }
done

OUT_ROOT="$TMP_ROOT/stage-root" IPK_DIR="$TMP_ROOT/ipk-a" \
  RELEASE_DIR="$TMP_ROOT/release" SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" RELEASE_PUBLIC_KEY="$PUBLIC" \
  RELEASE_KEY_ID="$KEY_ID" SIGNING_KEY="$SECRET" USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/stage-router-release.sh" >/dev/null
RELEASE_DIR="$TMP_ROOT/release" RELEASE_PUBLIC_KEY="$PUBLIC" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" >/dev/null
cmp -s "$TMP_ROOT/release/rd23-storage-geometry.json" \
  "$ROOT_DIR/release/rd23-storage-geometry.json"
jq -e --arg sha "$(sha256sum "$TMP_ROOT/release/rd23-storage-geometry.json" | awk '{print $1}')" \
  '.rd23_storage_geometry.filename == "rd23-storage-geometry.json" and
    .rd23_storage_geometry.sha256 == $sha' \
  "$TMP_ROOT/release/router-release-manifest.json" >/dev/null
cp "$TMP_ROOT/release/rd23-storage-geometry.json" "$TMP_ROOT/storage-geometry.good"
printf 'corruption\n' >> "$TMP_ROOT/release/rd23-storage-geometry.json"
if RELEASE_DIR="$TMP_ROOT/release" RELEASE_PUBLIC_KEY="$PUBLIC" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" \
  >"$TMP_ROOT/storage-geometry.log" 2>&1; then
  printf 'release validation accepted corrupted RD23 storage geometry\n' >&2
  exit 1
fi
grep -Eq 'SHA256SUMS validation failed|manifest RD23 storage geometry hash mismatch' \
  "$TMP_ROOT/storage-geometry.log"
mv "$TMP_ROOT/storage-geometry.good" "$TMP_ROOT/release/rd23-storage-geometry.json"

if RELEASE_DIR="$TMP_ROOT/release" RELEASE_PUBLIC_KEY="$PUBLIC" \
  EXPECTED_RELEASE_KEY_ID="$KEY_ID" EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  STRICT_RELEASE=1 USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/validate-staged-release.sh" \
  >"$TMP_ROOT/strict.log" 2>&1; then
  printf 'strict validation accepted an ephemeral test key\n' >&2
  exit 1
fi
grep -q 'strict release refuses a development key ID' "$TMP_ROOT/strict.log"

MANIFEST="$TMP_ROOT/release/router-release-manifest.json"
SIGNATURE="$TMP_ROOT/release/router-release-manifest.json.sig"
OPENWRT_RELEASE="$TMP_ROOT/openwrt_release"
printf "DISTRIB_RELEASE='24.10.5'\nDISTRIB_TARGET='x86/64'\n" > "$OPENWRT_RELEASE"
validate_manifest() {
  PREMIER_ROUTER_HOST_TEST=1 PR_OPENWRT_RELEASE_FILE="$OPENWRT_RELEASE" \
    sh -c '. "$1"; pr_manifest_validate "$2" "$3" 0.7.10 1' sh \
    "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" "$1" "$KEY_ID"
}
reject_filter() {
  name="$1"
  filter="$2"
  jq "$filter" "$MANIFEST" > "$TMP_ROOT/reject.json"
  if validate_manifest "$TMP_ROOT/reject.json" >/dev/null 2>&1; then
    printf 'manifest mutation was accepted: %s\n' "$name" >&2
    exit 1
  fi
}
validate_manifest "$MANIFEST" >/dev/null
reject_filter malformed-version '.app_version="0.7"'
reject_filter unsupported-schema '.schema_version=99'
reject_filter unsupported-protocol '.update_protocol=3'
reject_filter dirty-provenance '.source_dirty=true'
reject_filter missing-package '.packages=.packages[0:2]'
reject_filter extra-package '.packages += [.packages[0]]'
reject_filter duplicate-package '.packages[1]=.packages[0]'
reject_filter unsafe-filename '.packages[0].filename="../evil.ipk"'
reject_filter absolute-filename '.packages[0].filename="/tmp/evil.ipk"'
reject_filter architecture '.packages[0].architecture="mips"'
reject_filter unsupported-source '.transitions |= map(select(.source_version != "0.7.10"))'
reject_filter target-mismatch '.supported_targets=["mediatek/filogic"]'

"$USIGN_BIN" -q -V -p "$PUBLIC" -m "$MANIFEST" -x "$SIGNATURE"
cp "$SIGNATURE" "$TMP_ROOT/bad.sig"
printf 'x' >> "$TMP_ROOT/bad.sig"
if "$USIGN_BIN" -q -V -p "$PUBLIC" -m "$MANIFEST" -x "$TMP_ROOT/bad.sig"; then
  printf 'usign accepted a corrupted signature\n' >&2
  exit 1
fi
"$USIGN_BIN" -G -s "$TMP_ROOT/wrong.sec" -p "$TMP_ROOT/wrong.pub" -c 'wrong key'
if "$USIGN_BIN" -q -V -p "$TMP_ROOT/wrong.pub" -m "$MANIFEST" -x "$SIGNATURE"; then
  printf 'usign accepted a wrong key\n' >&2
  exit 1
fi

VPN_UI_UPDATE_SOURCE_ONLY=1 VPN_UI_UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  PREMIER_ROUTER_HOST_TEST=1 sh -c '. "$1"; validate_asset_set "$2" "$3"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" "$TMP_ROOT/release" "$MANIFEST"
cp "$TMP_ROOT/release/premier-router-core_0.7.11-1_all.ipk" "$TMP_ROOT/core.good"
printf 'corruption' >> "$TMP_ROOT/release/premier-router-core_0.7.11-1_all.ipk"
if VPN_UI_UPDATE_SOURCE_ONLY=1 \
  VPN_UI_UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  PREMIER_ROUTER_HOST_TEST=1 sh -c '. "$1"; validate_asset_set "$2" "$3"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" "$TMP_ROOT/release" "$MANIFEST"; then
  printf 'asset validation accepted a wrong hash/size\n' >&2
  exit 1
fi
mv "$TMP_ROOT/core.good" "$TMP_ROOT/release/premier-router-core_0.7.11-1_all.ipk"

owned_index=0
for ipk in "$TMP_ROOT/ipk-a"/*.ipk; do
  owned_index=$((owned_index + 1))
  owned_root="$TMP_ROOT/owned-$owned_index"
  mkdir -p "$owned_root"
  tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$owned_root"
  (cd "$owned_root" && find . \( -type f -o -type l \) -print | LC_ALL=C sort)
done | LC_ALL=C sort | uniq -d > "$TMP_ROOT/duplicate-owned-paths"
[ ! -s "$TMP_ROOT/duplicate-owned-paths" ] || {
  cat "$TMP_ROOT/duplicate-owned-paths" >&2
  printf 'project IPKs overlap ownership\n' >&2
  exit 1
}
tar -xzOf "$TMP_ROOT/ipk-a/premier-router-core_0.7.11-1_all.ipk" ./control.tar.gz |
  tar -xzOf - ./conffiles > "$TMP_ROOT/conffiles"
[ "$(cat "$TMP_ROOT/conffiles")" = /etc/vpn-ui-update.conf ] || exit 1
! tar -xzOf "$TMP_ROOT/ipk-a/luci-app-premier-router_0.7.11-1_all.ipk" ./data.tar.gz |
  tar -tzf - | grep -q '/_35_vpn.js$'

grep -q 'candidate_validate' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
grep -Fq 'VALIDATOR="$ASSET_DIR/$(jget "$MANIFEST" '\''@.candidate_validator.filename'\'')"' \
  "$ROOT_DIR/install-router-ui-release.sh"
grep -Fq 'chmod 700 "$SUPERVISOR" "$UPDATE_LIB" "$VALIDATOR"' \
  "$ROOT_DIR/install-router-ui-release.sh"
! grep -Eq 'curl -k|wget .*--no-check-certificate|opkg upgrade' \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" \
  "$ROOT_DIR/install-router-ui-release.sh" "$ROOT_DIR/rescue-router-ui.sh"

printf 'Router UI release-v2 package, signature, manifest, and asset tests passed\n'
