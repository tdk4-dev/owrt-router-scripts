#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'staging:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/release-v$APP_VERSION}"
case "$APP_VERSION" in *-rc.*) DEFAULT_RELEASE_CHANNEL=candidate ;; *) DEFAULT_RELEASE_CHANNEL=stable ;; esac
RELEASE_CHANNEL="${RELEASE_CHANNEL:-$DEFAULT_RELEASE_CHANNEL}"
EXPECTED_RELEASE_KEY_ID="${EXPECTED_RELEASE_KEY_ID:-}"
USIGN_BIN="${USIGN_BIN:-usign}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
REQUIRE_IMAGES="${REQUIRE_IMAGES:-0}"
REQUIRE_MAIN_ANCESTRY="${REQUIRE_MAIN_ANCESTRY:-$STRICT_RELEASE}"
EXPECTED_SOURCE_COMMIT="${EXPECTED_SOURCE_COMMIT:-}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-release-validate.XXXXXX")"
ROUTER_UI_RELEASE_ROOT="$ROOT_DIR"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
strict_trust_script_matches() {
  script="$1"
  expected_comment="$2"
  expected_data="$3"
  ! grep -q 'UNRENDERED-PRODUCTION' "$script" || return 1
  [ "$(grep -c '^TRUSTED_KEY_ID=' "$script")" = 1 ] &&
    [ "$(grep -c '^TRUSTED_KEY_FINGERPRINT=' "$script")" = 1 ] &&
    [ "$(grep -c '^TRUSTED_KEY_COMMENT=' "$script")" = 1 ] &&
    [ "$(grep -c '^TRUSTED_KEY_DATA=' "$script")" = 1 ] || return 1
  grep -Fqx "TRUSTED_KEY_ID='$EXPECTED_RELEASE_KEY_ID'" "$script" &&
    grep -Fqx "TRUSTED_KEY_FINGERPRINT='$RELEASE_KEY_FINGERPRINT'" "$script" &&
    grep -Fqx "TRUSTED_KEY_COMMENT='$expected_comment'" "$script" &&
    grep -Fqx "TRUSTED_KEY_DATA='$expected_data'" "$script"
}
for tool in awk cmp find grep gzip jq sed sha256sum sort tar wc "$USIGN_BIN"; do need "$tool"; done

[ "${APP_VERSION%%-rc.*}" = 0.7.11 ] || fail "validator is scoped to Router UI 0.7.11"
case "$RELEASE_CHANNEL" in candidate|stable) ;; *) fail "unsupported release channel: $RELEASE_CHANNEL" ;; esac
[ -d "$RELEASE_DIR" ] || fail "missing release directory: $RELEASE_DIR"
for file in router-release-manifest.json router-release-manifest.json.sig \
  "$RELEASE_CHANNEL-channel.json" "$RELEASE_CHANNEL-channel.json.sig" release-provenance.json \
  release-provenance.json.sig SHA256SUMS SHA256SUMS.sig router-ui-packages.txt \
  INSTALLATION-RECOVERY.md \
  install-router-ui-release.sh install-router-ui-release.sh.sha256 \
  bootstrap-router-ui-ipk-install.sh bootstrap-router-ui-ipk-install.sh.sha256 \
  rescue-router-ui.sh rescue-router-ui.sh.sha256 luci-vpn-ui.tar.gz \
  luci-vpn-ui.tar.gz.sha256 vpn-ui-version.txt vpn-ui-changelog.txt \
  vpn-ui-release-date.txt router-candidate-validator router-update-supervisor \
  router-update-lib.sh 0.7.9-_35_vpn.js rd23-storage-geometry.json \
  installed-manifest.json installed-manifest.json.sig trusted-keys.json \
  release-signing-key-id historical-rescue-support-matrix.json \
  historical-rescue-support-matrix.md RELEASE-NOTES.md \
  "premier-router-opkg-feed-$APP_VERSION.tar.gz"
do
  [ -s "$RELEASE_DIR/$file" ] || fail "missing staged asset: $file"
done

[ -z "$(find "$RELEASE_DIR" -mindepth 1 -type d -print)" ] ||
  fail "release set must be flat"
jq -e --arg target "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg channel "$RELEASE_CHANNEL" '
  .schema_version == 2 and .target == $target and
  .package_version == $package and .release_channel == $channel and
  (.baselines | type == "array" and length > 0)
' "$RELEASE_DIR/historical-rescue-support-matrix.json" >/dev/null ||
  fail "embedded historical rescue matrix target identity mismatch"
[ -z "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.ipk' |
  sed 's#^.*/##' | sort | uniq -d)" ] || fail "duplicate IPK asset names"

(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS > "$WORK/sha256.log"
) || { cat "$WORK/sha256.log" >&2; fail "SHA256SUMS validation failed"; }
find "$RELEASE_DIR" -maxdepth 1 -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -exec basename {} \; |
  LC_ALL=C sort > "$WORK/files.actual"
awk '{print $2}' "$RELEASE_DIR/SHA256SUMS" | sed 's#^\*##' | LC_ALL=C sort > "$WORK/files.sum"
cmp -s "$WORK/files.actual" "$WORK/files.sum" || fail "SHA256SUMS names do not exactly match flat assets"
for file in luci-vpn-ui.tar.gz install-router-ui-release.sh \
  bootstrap-router-ui-ipk-install.sh rescue-router-ui.sh
do
  expected="$(awk -v f="$file" '$2 == f || $2 == "*" f {print $1}' "$RELEASE_DIR/$file.sha256")"
  [ "$expected" = "$(sha256sum "$RELEASE_DIR/$file" | awk '{print $1}')" ] ||
    fail "$file sidecar mismatch"
done

MANIFEST="$RELEASE_DIR/router-release-manifest.json"
POINTER="$RELEASE_DIR/$RELEASE_CHANNEL-channel.json"
PROVENANCE="$RELEASE_DIR/release-provenance.json"
MANIFEST_KEY_ID="$(jq -er '.signing_key_id | select(type == "string")' "$MANIFEST")" ||
  fail "manifest signing key ID is missing"
[ -z "$EXPECTED_RELEASE_KEY_ID" ] || [ "$EXPECTED_RELEASE_KEY_ID" = "$MANIFEST_KEY_ID" ] ||
  fail "manifest signing key ID differs from expected key ID"
EXPECTED_RELEASE_KEY_ID="$MANIFEST_KEY_ID"
pr_select_trusted_key "$EXPECTED_RELEASE_KEY_ID" 'active previous' || exit 1
[ -s "$RELEASE_DIR/$EXPECTED_RELEASE_KEY_ID.pub" ] || fail "staged release public key is missing"
cmp -s "$RELEASE_PUBLIC_KEY" "$RELEASE_DIR/$EXPECTED_RELEASE_KEY_ID.pub" || fail "staged release public key differs from registry"
[ "$(sed -n '1p' "$RELEASE_DIR/release-signing-key-id")" = "$EXPECTED_RELEASE_KEY_ID" ] || fail "staged signing key ID mismatch"
[ "$(sed -n '1p' "$RELEASE_DIR/$EXPECTED_RELEASE_KEY_ID.fingerprint")" = "$RELEASE_KEY_FINGERPRINT" ] || fail "staged signing fingerprint mismatch"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$MANIFEST" \
  -x "$RELEASE_DIR/router-release-manifest.json.sig" || fail "manifest signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$POINTER" \
  -x "$RELEASE_DIR/$RELEASE_CHANNEL-channel.json.sig" || fail "$RELEASE_CHANNEL pointer signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$PROVENANCE" \
  -x "$RELEASE_DIR/release-provenance.json.sig" || fail "provenance signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$RELEASE_DIR/SHA256SUMS" \
  -x "$RELEASE_DIR/SHA256SUMS.sig" || fail "SHA256SUMS signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$RELEASE_DIR/installed-manifest.json" \
  -x "$RELEASE_DIR/installed-manifest.json.sig" || fail "installed manifest signature invalid"

if [ -n "${FACTORY_PRODUCT_VERSION:-}" ]; then
  for file in factory-release-contract.json factory-release-contract.json.sig \
    factory-router-release-manifest.json factory-router-release-manifest.json.sig \
    image-package-manifest.json
  do
    [ -s "$RELEASE_DIR/$file" ] || fail "missing Factory schema-2 asset: $file"
  done
  "$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" \
    -m "$RELEASE_DIR/factory-release-contract.json" \
    -x "$RELEASE_DIR/factory-release-contract.json.sig" ||
    fail "Factory contract signature invalid"
  "$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" \
    -m "$RELEASE_DIR/factory-router-release-manifest.json" \
    -x "$RELEASE_DIR/factory-router-release-manifest.json.sig" ||
    fail "Factory release manifest signature invalid"
  jq -e --arg version "$FACTORY_PRODUCT_VERSION" --arg package "$PKG_VERSION" \
    --arg commit "$(jq -er .source_commit "$MANIFEST")" \
    --arg manifest_sha "$(sha256sum "$RELEASE_DIR/factory-router-release-manifest.json" |
      awk '{print $1}')" '
    .schema_version == 2 and .semantic_version == $version and
    .product_version == $version and .package_release == $package and
    .source_commit == $commit and .release_channel == "rc" and
    .prerelease == true and .release_manifest_sha256 == $manifest_sha and
    (.artifacts | length == 1) and
    .artifacts[0].hardware_target == "x86/64" and
    .artifacts[0].image_profile == "generic" and
    .artifacts[0].variant == "virtualbox"
  ' "$RELEASE_DIR/factory-release-contract.json" >/dev/null ||
    fail "Factory schema-2 contract authority fields mismatch"
  jq -e --arg version "$FACTORY_PRODUCT_VERSION" --arg package "$PKG_VERSION" \
    --arg commit "$(jq -er .source_commit "$MANIFEST")" '
    .schema_version == 2 and .app_version == $version and
    .package_version == $package and .source_commit == $commit and
    .channel == "candidate" and .prerelease == true and
    (.images | length == 1) and .images[0].target == "x86/64"
  ' "$RELEASE_DIR/factory-router-release-manifest.json" >/dev/null ||
    fail "Factory schema-2 manifest authority fields mismatch"
fi

printf "DISTRIB_RELEASE='%s'\nDISTRIB_TARGET='x86/64'\n" "$OPENWRT_VERSION" > "$WORK/openwrt_release"
PREMIER_ROUTER_HOST_TEST=1 PR_USIGN_BIN="$USIGN_BIN" \
  PR_OPENWRT_RELEASE_FILE="$WORK/openwrt_release" \
  sh -c '. "$1"; pr_manifest_validate "$2" "$3" 0.7.10 1' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  "$MANIFEST" "$EXPECTED_RELEASE_KEY_ID" || fail "manifest semantic validation failed"

jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg channel "$RELEASE_CHANNEL" \
  --argjson require_images "$REQUIRE_IMAGES" \
  --arg tag "vpn-panel-v$APP_VERSION" --arg key "$EXPECTED_RELEASE_KEY_ID" \
  --arg fingerprint "$RELEASE_KEY_FINGERPRINT" '
  .schema_version == 2 and .update_protocol == 2 and .channel == $channel and
  .app_version == $version and .package_version == $package and
  .release_tag == $tag and .signing_key_id == $key and
  .signing_key_fingerprint == $fingerprint and .source_dirty == false and
  (.source_commit | test("^[0-9a-f]{40}$")) and
  .rd23_storage_geometry.filename == "rd23-storage-geometry.json" and
  .package_feed.filename == ("premier-router-opkg-feed-" + $version + ".tar.gz") and
  .installed_package_manifest.filename == "installed-manifest.json" and
  (($require_images == 0) or ((.images | length == 3) and
    ([.images[].storage.storage_profile] | sort == ["rd23-stock","rd23-stock","rd23-ubootmod"]))) and
  (.transitions | map(.source_version) | index("0.7.7") | not) and
  ([.packages[].install_order] == [1,2,3]) and
  ([.packages[].name] == ["premier-router-core","luci-app-premier-router","premier-router-setup"])
' "$MANIFEST" >/dev/null || fail "manifest authority fields mismatch"
if [ "$RELEASE_CHANNEL" = stable ]; then
  jq -e '
    .app_version == "0.7.11" and .package_version == "0.7.11-1" and
    any(.transitions[];
      .source_version == "0.7.11-rc.14" and .source_protocol == 2 and
      .mode == "package-v2-rc")
  ' "$MANIFEST" >/dev/null || fail "stable release does not authorize the RC14 protocol-2 transition"
else
  jq -e '
    .app_version == "0.7.11-rc.14" and .package_version == "0.7.11~rc14-1" and
    any(.transitions[];
      .source_version == "0.7.11-rc.5" and .source_protocol == 2 and
      .mode == "package-v2-rc") and
    any(.transitions[];
      .source_version == "0.7.11-rc.6" and .source_protocol == 2 and
      .mode == "package-v2-rc") and
    any(.transitions[];
      .source_version == "0.7.11-rc.7" and .source_protocol == 2 and
      .mode == "package-v2-rc")
  ' "$MANIFEST" >/dev/null || fail "RC14 release does not authorize the RC5, RC6, and invalidated RC7 protocol-2 transitions"
fi
[ "$(jq -r '.rd23_storage_geometry.sha256' "$MANIFEST")" = \
  "$(sha256sum "$RELEASE_DIR/rd23-storage-geometry.json" | awk '{print $1}')" ] ||
  fail "manifest RD23 storage geometry hash mismatch"
MANIFEST_COMMIT="$(jq -r .source_commit "$MANIFEST")"
[ -z "$EXPECTED_SOURCE_COMMIT" ] || [ "$MANIFEST_COMMIT" = "$EXPECTED_SOURCE_COMMIT" ] ||
  fail "manifest source commit differs from expected commit"
jq -e --arg version "$APP_VERSION" --arg tag "vpn-panel-v$APP_VERSION" \
  --arg channel "$RELEASE_CHANNEL" \
  --arg hash "$(sha256sum "$MANIFEST" | awk '{print $1}')" \
  --arg key "$EXPECTED_RELEASE_KEY_ID" --arg fingerprint "$RELEASE_KEY_FINGERPRINT" '
  .schema_version == 1 and .channel == $channel and .target_version == $version and
  .release_tag == $tag and .manifest_filename == "router-release-manifest.json" and
  .manifest_sha256 == $hash and .signing_key_id == $key and
  .signing_key_fingerprint == $fingerprint
' "$POINTER" >/dev/null || fail "$RELEASE_CHANNEL pointer does not pin the exact manifest"
jq -e --arg filename bootstrap-router-ui-ipk-install.sh \
  --arg hash "$(sha256sum "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh" | awk '{print $1}')" '
  .initial_ipk_bootstrap.filename == $filename and
  .initial_ipk_bootstrap.sha256 == $hash and
  .initial_ipk_bootstrap.protocol == 1
' "$MANIFEST" >/dev/null || fail "initial IPK bootstrap manifest metadata mismatch"
grep -Fqx "TARGET_APP_VERSION='$APP_VERSION'" \
  "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh" || fail "bootstrap app version was not rendered"
grep -Fqx "TARGET_PACKAGE_VERSION='$PKG_VERSION'" \
  "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh" || fail "bootstrap package version was not rendered"
grep -Fqx "TARGET_VERSION=$APP_VERSION" "$RELEASE_DIR/rescue-router-ui.sh" ||
  fail "rescue target version was not rendered"
jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg commit "$MANIFEST_COMMIT" --arg key "$EXPECTED_RELEASE_KEY_ID" \
  --arg fingerprint "$RELEASE_KEY_FINGERPRINT" '
  .schema_version == 1 and .app_version == $version and .package_version == $package and
  .source_commit == $commit and .source_dirty == false and .signing_key_id == $key and
  .signing_key_fingerprint == $fingerprint and
  (.canonical_ipks | length == 3)
' "$PROVENANCE" >/dev/null || fail "release provenance mismatch"

ipk_control() { tar -xzOf "$1" ./control.tar.gz | tar -xzOf - ./control; }
ipk_data() { tar -xzOf "$1" ./data.tar.gz; }
index=0
for package in $PROJECT_PACKAGES; do
  ipk="$RELEASE_DIR/${package}_${PKG_VERSION}_all.ipk"
  [ -s "$ipk" ] || fail "missing canonical IPK: $(basename "$ipk")"
  [ "$(ipk_control "$ipk" | sed -n 's/^Package: //p')" = "$package" ] || fail "$package control name mismatch"
  [ "$(ipk_control "$ipk" | sed -n 's/^Version: //p')" = "$PKG_VERSION" ] || fail "$package control version mismatch"
  [ "$(ipk_control "$ipk" | sed -n 's/^Architecture: //p')" = all ] || fail "$package architecture mismatch"
  manifest_name="$(jq -r ".packages[$index].filename" "$MANIFEST")"
  [ "$manifest_name" = "$(basename "$ipk")" ] || fail "$package manifest filename mismatch"
  [ "$(jq -r ".packages[$index].size" "$MANIFEST")" = "$(wc -c < "$ipk" | tr -d ' ')" ] || fail "$package size mismatch"
  [ "$(jq -r ".packages[$index].sha256" "$MANIFEST")" = "$(sha256sum "$ipk" | awk '{print $1}')" ] || fail "$package hash mismatch"
  grep -Eq "^$package $PKG_VERSION all $(sha256sum "$ipk" | awk '{print $1}') $(wc -c < "$ipk" | tr -d ' ') $(basename "$ipk")$" \
    "$RELEASE_DIR/router-ui-packages.txt" || fail "canonical package manifest mismatch for $package"
  index=$((index + 1))
done
[ "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.ipk' | wc -l | tr -d ' ')" = 3 ] ||
  fail "flat release must contain exactly three IPKs"

INSTALLED_MANIFEST="$RELEASE_DIR/installed-manifest.json"
jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg commit "$MANIFEST_COMMIT" --arg key "$EXPECTED_RELEASE_KEY_ID" \
  --arg fingerprint "$RELEASE_KEY_FINGERPRINT" '
  .schema_version == 1 and .kind == "installed-package-set" and
  .app_version == $version and .package_version == $package and
  .source_commit == $commit and .source_dirty == false and
  .signing_key_id == $key and .signing_key_fingerprint == $fingerprint and
  ([.packages[].name] == ["premier-router-core","luci-app-premier-router","premier-router-setup"])
' "$INSTALLED_MANIFEST" >/dev/null || fail "installed package manifest metadata mismatch"
for index in 0 1 2; do
  filename="$(jq -r ".packages[$index].filename" "$INSTALLED_MANIFEST")"
  [ "$(jq -r ".packages[$index].sha256" "$INSTALLED_MANIFEST")" = \
    "$(sha256sum "$RELEASE_DIR/$filename" | awk '{print $1}')" ] ||
    fail "installed package manifest hash mismatch: $filename"
done

FEED_ARCHIVE="$RELEASE_DIR/premier-router-opkg-feed-$APP_VERSION.tar.gz"
[ "$(jq -r '.package_feed.sha256' "$MANIFEST")" = "$(sha256sum "$FEED_ARCHIVE" | awk '{print $1}')" ] ||
  fail "manifest package-feed hash mismatch"
if tar -tzf "$FEED_ARCHIVE" | grep -Eq '(^|/)\.\.(/|$)|^/'; then
  fail "candidate feed archive contains an unsafe member"
fi
mkdir -p "$WORK/feed"
tar -xzf "$FEED_ARCHIVE" -C "$WORK/feed"
FEED_ROOT="$WORK/feed"
[ -s "$FEED_ROOT/Packages" ] || FEED_ROOT="$WORK/feed/."
(cd "$FEED_ROOT" && sha256sum -c SHA256SUMS >/dev/null) || fail "candidate feed checksum validation failed"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$FEED_ROOT/Packages" \
  -x "$FEED_ROOT/Packages.sig" || fail "candidate opkg feed signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$FEED_ROOT/feed-provenance.json" \
  -x "$FEED_ROOT/feed-provenance.json.sig" || fail "candidate feed provenance signature invalid"
jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg channel "$RELEASE_CHANNEL" --arg commit "$MANIFEST_COMMIT" '
  .schema_version == 1 and .kind == "opkg-feed" and .channel == $channel and
  .app_version == $version and .package_version == $package and
  .source_commit == $commit and .source_dirty == false
' "$FEED_ROOT/feed-provenance.json" >/dev/null || fail "opkg feed provenance metadata mismatch"
gzip -dc "$FEED_ROOT/Packages.gz" | cmp -s - "$FEED_ROOT/Packages" || fail "candidate feed compressed index mismatch"
for package in $PROJECT_PACKAGES; do
  cmp -s "$RELEASE_DIR/${package}_${PKG_VERSION}_all.ipk" \
    "$FEED_ROOT/${package}_${PKG_VERSION}_all.ipk" || fail "candidate feed package drift: $package"
done

mkdir -p "$WORK/core"
ipk_data "$RELEASE_DIR/premier-router-core_${PKG_VERSION}_all.ipk" | tar -xzf - -C "$WORK/core"
cmp -s "$WORK/core/usr/sbin/vpn-ui-update" "$RELEASE_DIR/router-update-supervisor" ||
  fail "published supervisor was not derived from canonical core IPK"
cmp -s "$WORK/core/usr/libexec/premier-router/update-lib.sh" "$RELEASE_DIR/router-update-lib.sh" ||
  fail "published update library was not derived from canonical core IPK"
cmp -s "$WORK/core/usr/libexec/premier-router/candidate-validator" "$RELEASE_DIR/router-candidate-validator" ||
  fail "published validator was not derived from canonical core IPK"
cmp -s "$WORK/core/usr/sbin/install-router-ui-release" "$RELEASE_DIR/install-router-ui-release.sh" ||
  fail "published installer was not derived from canonical core IPK"
grep -Fqx "RELEASE_KEY_ID=$EXPECTED_RELEASE_KEY_ID" "$WORK/core/usr/share/premier-router/build-info" ||
  fail "core IPK release key ID mismatch"
grep -Fqx "RELEASE_KEY_FINGERPRINT=$RELEASE_KEY_FINGERPRINT" \
  "$WORK/core/usr/share/premier-router/build-info" ||
  fail "core IPK release key fingerprint mismatch"
grep -Fqx "SOURCE_COMMIT=$MANIFEST_COMMIT" "$WORK/core/usr/share/premier-router/build-info" ||
  fail "core IPK source commit mismatch"
grep -Fqx 'SOURCE_DIRTY=false' "$WORK/core/usr/share/premier-router/build-info" ||
  fail "core IPK dirty provenance"

mkdir -p "$WORK/bundle"
tar -xzf "$RELEASE_DIR/luci-vpn-ui.tar.gz" -C "$WORK/bundle"
BUNDLE="$WORK/bundle/luci-vpn-ui"
[ -x "$BUNDLE/install.sh" ] || fail "bundle installer missing"
for package in $PROJECT_PACKAGES; do
  cmp -s "$RELEASE_DIR/${package}_${PKG_VERSION}_all.ipk" \
    "$BUNDLE/bridge/${package}_${PKG_VERSION}_all.ipk" || fail "bundle IPK drift: $package"
done
cmp -s "$MANIFEST" "$BUNDLE/bridge/router-release-manifest.json" || fail "bundle manifest drift"
cmp -s "$RELEASE_DIR/router-update-supervisor" "$BUNDLE/bridge/vpn-ui-update" || fail "bundle supervisor drift"
cmp -s "$RELEASE_DIR/router-update-lib.sh" "$BUNDLE/bridge/update-lib.sh" || fail "bundle library drift"
cmp -s "$RELEASE_DIR/router-candidate-validator" "$BUNDLE/bridge/router-candidate-validator" || fail "bundle validator drift"
[ -z "$(find "$BUNDLE" -type f \( -path '*/usr/*' -o -path '*/www/*' -o -path '*/etc/*' \) -print)" ] ||
  fail "compatibility bundle contains independently copied application files"
[ "$(find "$BUNDLE/bridge" -maxdepth 1 -type f -name '*.ipk' | wc -l | tr -d ' ')" = 3 ] ||
  fail "bundle has stale or extra IPKs"

image_count="$(find "$RELEASE_DIR" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" | wc -l | tr -d ' ')"
if [ "$REQUIRE_IMAGES" = 1 ] && [ "$image_count" -lt 3 ]; then
  fail "release requires x86, RD23 stock, and RD23 ubootmod image archives"
fi
find "$RELEASE_DIR" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" |
  while IFS= read -r archive; do
    archive_root="$WORK/$(basename "$archive").root"
    mkdir -p "$archive_root"
    tar -xzf "$archive" -C "$archive_root"
    artifact_root="$(find "$archive_root" -mindepth 1 -maxdepth 1 -type d | sed -n '1p')"
    [ -n "$artifact_root" ] || fail "image archive has no artifact root"
    diagnostic_provenance="$(find "$artifact_root" -type f -name image-provenance.json | sed -n '1p')"
    if [ -n "$diagnostic_provenance" ] &&
      jq -e '.diagnostic_geometry_only == true' "$diagnostic_provenance" >/dev/null 2>&1; then
      fail "diagnostic geometry-only archive is not a release image: $(basename "$archive")"
    fi
    (cd "$artifact_root" && sha256sum -c sha256sums >/dev/null) ||
      fail "image internal checksum manifest failed: $(basename "$archive")"
    [ -s "$artifact_root/project-payload-sha256sums" ] ||
      fail "image lacks package payload proof: $(basename "$archive")"
    cmp -s "$artifact_root/rd23-storage-geometry.json" \
      "$ROOT_DIR/release/rd23-storage-geometry.json" ||
      fail "image RD23 storage geometry drift: $(basename "$archive")"
    [ -s "$artifact_root/overlay-files.txt" ] || fail "image overlay evidence is missing"
    if grep -Ev '^(www/index\.html|etc/premier-router/installed-manifest\.json(\.sig)?|root/premier-router-updates/known-good/[0-9a-f]{64}/[^/]+)$' \
      "$artifact_root/overlay-files.txt" | grep -q .; then
      fail "image overlay contains files outside the redirect and exact package-recovery set"
    fi
    [ -s "$archive.sha256" ] &&
      [ "$(awk '{print $1}' "$archive.sha256")" = "$(sha256sum "$archive" | awk '{print $1}')" ] ||
      fail "image archive sidecar checksum mismatch: $(basename "$archive")"
    members="$WORK/$(basename "$archive").members"
    tar -tzf "$archive" > "$members"
    hashes_member="$(grep '/project-ipk-sha256sums$' "$members" | sed -n '1p')"
    provenance_member="$(grep '/image-provenance.json$' "$members" | sed -n '1p')"
    package_member="$(grep '/router-ui-packages.txt$' "$members" | sed -n '1p')"
    [ -n "$hashes_member" ] && [ -n "$provenance_member" ] && [ -n "$package_member" ] ||
      fail "image archive lacks package identity or provenance: $(basename "$archive")"
    tar -xOzf "$archive" "$hashes_member" > "$WORK/image.hashes"
    tar -xOzf "$archive" "$package_member" > "$WORK/image.packages"
    cmp -s "$WORK/image.packages" "$RELEASE_DIR/router-ui-packages.txt" || fail "image package manifest drift"
    for package in $PROJECT_PACKAGES; do
      ipk="${package}_${PKG_VERSION}_all.ipk"
      expected="$(sha256sum "$RELEASE_DIR/$ipk" | awk '{print $1}')"
      actual="$(awk -v f="$ipk" '$2 == f || $2 == "./" f {print $1}' "$WORK/image.hashes")"
      [ "$actual" = "$expected" ] || fail "image IPK hash drift for $ipk"
    done
    tar -xOzf "$archive" "$provenance_member" > "$WORK/image.provenance"
    jq -e --arg commit "$MANIFEST_COMMIT" --arg version "$OPENWRT_VERSION" '
      .source_commit == $commit and .source_dirty == false and
      .openwrt_version == $version and .updater_protocol == 2 and
      (.imagebuilder_local_key_mode == "locked" or
        .imagebuilder_local_key_mode == "generated") and
      (.imagebuilder_local_key_fingerprint |
        type == "string" and test("^[0-9a-f]{16}$"))
    ' "$WORK/image.provenance" >/dev/null || fail "image provenance mismatch"
    if [ "${REQUIRE_PINNED_IMAGEBUILDER_KEY:-0}" = 1 ]; then
      jq -e '.imagebuilder_local_key_mode == "locked"' \
        "$WORK/image.provenance" >/dev/null ||
        fail "image was not built with a pinned reproducibility key"
    fi
    case "$(jq -r .profile "$WORK/image.provenance")" in
      generic)
        jq -e '.storage_profile == "rd23-stock" and
          .writable_budget_kib > 0 and
          .writable_backing_kib == .writable_budget_kib and
          .x86_rootfs_partsize_kib > .writable_backing_kib and
          .rd23_storage_layout == null' "$WORK/image.provenance" >/dev/null ||
          fail "x86 image does not declare an exact RD23-stock writable extent"
        cp "$WORK/image.provenance" "$WORK/provenance.x86.json"
        ;;
      xiaomi_mi-router-ax3000t)
        storage_image="$(find "$artifact_root" -maxdepth 1 -type f \
          -name '*xiaomi_mi-router-ax3000t-squashfs-sysupgrade.bin' | sed -n '1p')"
        [ -n "$storage_image" ] || fail "RD23 stock storage payload is missing"
        "$ROOT_DIR/scripts/derive-rd23-storage-layout.sh" rd23-stock "$storage_image" \
          > "$WORK/storage.derived.json"
        jq -S '.rd23_storage_layout' "$WORK/image.provenance" > "$WORK/storage.provenance.json"
        cmp -s "$WORK/storage.derived.json" "$WORK/storage.provenance.json" ||
          fail "RD23 stock storage derivation drift"
        jq -e '.storage_profile == "rd23-stock" and
          .writable_backing_kib == .rd23_storage_layout.rootfs_data_volume_kib and
          .expected_ubifs_df_total_kib == .rd23_storage_layout.expected_ubifs_df_total_kib' \
          "$WORK/image.provenance" >/dev/null || fail "RD23 stock storage provenance mismatch"
        cp "$WORK/image.provenance" "$WORK/provenance.stock.json"
        ;;
      xiaomi_mi-router-ax3000t-ubootmod)
        storage_image="$(find "$artifact_root" -maxdepth 1 -type f \
          -name '*xiaomi_mi-router-ax3000t-ubootmod-squashfs-sysupgrade.itb' | sed -n '1p')"
        [ -n "$storage_image" ] || fail "RD23 ubootmod storage payload is missing"
        "$ROOT_DIR/scripts/derive-rd23-storage-layout.sh" rd23-ubootmod "$storage_image" \
          > "$WORK/storage.derived.json"
        jq -S '.rd23_storage_layout' "$WORK/image.provenance" > "$WORK/storage.provenance.json"
        cmp -s "$WORK/storage.derived.json" "$WORK/storage.provenance.json" ||
          fail "RD23 ubootmod storage derivation drift"
        jq -e '.storage_profile == "rd23-ubootmod" and
          .writable_backing_kib == .rd23_storage_layout.rootfs_data_volume_kib and
          .expected_ubifs_df_total_kib == .rd23_storage_layout.expected_ubifs_df_total_kib' \
          "$WORK/image.provenance" >/dev/null || fail "RD23 ubootmod storage provenance mismatch"
        cp "$WORK/image.provenance" "$WORK/provenance.ubootmod.json"
        ;;
      *) fail "unexpected image profile in provenance" ;;
    esac
  done

if [ "$REQUIRE_IMAGES" = 1 ]; then
  for provenance in x86 stock ubootmod; do
    [ -s "$WORK/provenance.$provenance.json" ] || fail "missing $provenance image storage provenance"
  done
  x86_backing="$(jq -r '.writable_backing_kib' "$WORK/provenance.x86.json")"
  stock_backing="$(jq -r '.writable_backing_kib' "$WORK/provenance.stock.json")"
  [ "$x86_backing" = "$stock_backing" ] ||
    fail "x86 writable extent is not the exact derived RD23-stock extent"
fi

if [ "$STRICT_RELEASE" = 1 ]; then
  case "$EXPECTED_RELEASE_KEY_ID" in test-*|dev-*|development-*) fail "strict release refuses a development key ID" ;; esac
  grep -Eqi 'development|test key' "$RELEASE_PUBLIC_KEY" && fail "strict release refuses a development public key"
  pr_require_committed_registry || exit 1
  expected_comment="$(sed -n '1p' "$RELEASE_PUBLIC_KEY" | tr -d '\r\n')"
  expected_data="$(sed -n '2p' "$RELEASE_PUBLIC_KEY" | tr -d '\r\n')"
  for script in "$RELEASE_DIR/install-router-ui-release.sh" \
    "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh" \
    "$RELEASE_DIR/rescue-router-ui.sh"
  do
    strict_trust_script_matches "$script" "$expected_comment" "$expected_data" ||
      fail "strict release bootstrap trust root differs from the committed production key"
  done
  [ -n "$EXPECTED_SOURCE_COMMIT" ] || fail "strict release requires EXPECTED_SOURCE_COMMIT"
  if [ "$REQUIRE_MAIN_ANCESTRY" = 1 ]; then
    git -C "$ROOT_DIR" merge-base --is-ancestor "$EXPECTED_SOURCE_COMMIT" origin/main ||
      fail "release source commit is not contained in origin/main"
  fi
fi

if find "$RELEASE_DIR" -type f \( -name '*.sec' -o -name '*.key' -o -name '*.pem' \
  -o -name '.env' -o -name 'id_rsa*' -o -name 'id_ed25519*' \) | grep -q .; then
  fail "release set contains a secret-key-shaped filename"
fi
if grep -RIlE '(^|[^A-Za-z])(ROUTER_UI_SIGNING_KEY=|BEGIN (OPENSSH |RSA |EC )?PRIVATE KEY|/Users/|/private/tmp/|/home/[^/]+/)' \
  "$RELEASE_DIR" | grep -q .; then
  fail "release set contains a private path or secret-material indicator"
fi
! grep -RIl 'a4d8987' "$RELEASE_DIR" | grep -q . ||
  fail "release set contains historical candidate provenance"

printf 'staged release validation passed: %s (%s assets, %s images)\n' \
  "$RELEASE_DIR" "$(wc -l < "$WORK/files.actual" | tr -d ' ')" "$image_count"
