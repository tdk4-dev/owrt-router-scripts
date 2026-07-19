#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$APP_VERSION-${PKG_RELEASE:-1}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/release-v$APP_VERSION}"
RELEASE_PUBLIC_KEY="${RELEASE_PUBLIC_KEY:-$ROOT_DIR/tests/fixtures/keys/router-ui-test.pub}"
EXPECTED_RELEASE_KEY_ID="${EXPECTED_RELEASE_KEY_ID:-test-21ff375c021d4c72}"
USIGN_BIN="${USIGN_BIN:-usign}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
REQUIRE_IMAGES="${REQUIRE_IMAGES:-0}"
EXPECTED_SOURCE_COMMIT="${EXPECTED_SOURCE_COMMIT:-}"
VALIDATION_SOURCE_VERSION="${VALIDATION_SOURCE_VERSION:-}"
VALIDATION_SOURCE_PROTOCOL="${VALIDATION_SOURCE_PROTOCOL:-}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-release-validate.XXXXXX")"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for tool in awk cmp find grep gzip jq sed sha256sum sort tar wc "$USIGN_BIN"; do need "$tool"; done

[ -d "$RELEASE_DIR" ] || fail "missing release directory: $RELEASE_DIR"
[ -s "$RELEASE_PUBLIC_KEY" ] || fail "missing release public key"
for file in router-release-manifest.json router-release-manifest.json.sig \
  stable-channel.json stable-channel.json.sig release-provenance.json \
  release-provenance.json.sig SHA256SUMS router-ui-packages.txt \
  install-router-ui-release.sh install-router-ui-release.sh.sha256 \
  rescue-router-ui.sh rescue-router-ui.sh.sha256 vpn-ui-version.txt vpn-ui-changelog.txt \
  vpn-ui-release-date.txt router-candidate-validator router-update-supervisor \
  router-update-lib.sh 0.7.9-_35_vpn.js
do
  [ -s "$RELEASE_DIR/$file" ] || fail "missing staged asset: $file"
done
if [ "$APP_VERSION" = 0.7.11 ]; then
  for file in luci-vpn-ui.tar.gz luci-vpn-ui.tar.gz.sha256; do
    [ -s "$RELEASE_DIR/$file" ] || fail "missing 0.7.11 compatibility asset: $file"
  done
fi

[ -z "$(find "$RELEASE_DIR" -mindepth 1 -type d -print)" ] ||
  fail "release set must be flat"
[ -z "$(find "$RELEASE_DIR" -maxdepth 1 -type f -name '*.ipk' |
  sed 's#^.*/##' | sort | uniq -d)" ] || fail "duplicate IPK asset names"

(
  cd "$RELEASE_DIR"
  sha256sum -c SHA256SUMS > "$WORK/sha256.log"
) || { cat "$WORK/sha256.log" >&2; fail "SHA256SUMS validation failed"; }
find "$RELEASE_DIR" -maxdepth 1 -type f ! -name SHA256SUMS -exec basename {} \; |
  LC_ALL=C sort > "$WORK/files.actual"
awk '{print $2}' "$RELEASE_DIR/SHA256SUMS" | sed 's#^\*##' | LC_ALL=C sort > "$WORK/files.sum"
cmp -s "$WORK/files.actual" "$WORK/files.sum" || fail "SHA256SUMS names do not exactly match flat assets"
sidecar_files="install-router-ui-release.sh rescue-router-ui.sh"
[ "$APP_VERSION" != 0.7.11 ] || sidecar_files="luci-vpn-ui.tar.gz $sidecar_files"
for file in $sidecar_files; do
  expected="$(awk -v f="$file" '$2 == f || $2 == "*" f {print $1}' "$RELEASE_DIR/$file.sha256")"
  [ "$expected" = "$(sha256sum "$RELEASE_DIR/$file" | awk '{print $1}')" ] ||
    fail "$file sidecar mismatch"
done

MANIFEST="$RELEASE_DIR/router-release-manifest.json"
POINTER="$RELEASE_DIR/stable-channel.json"
PROVENANCE="$RELEASE_DIR/release-provenance.json"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$MANIFEST" \
  -x "$RELEASE_DIR/router-release-manifest.json.sig" || fail "manifest signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$POINTER" \
  -x "$RELEASE_DIR/stable-channel.json.sig" || fail "stable pointer signature invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$PROVENANCE" \
  -x "$RELEASE_DIR/release-provenance.json.sig" || fail "provenance signature invalid"

printf "DISTRIB_RELEASE='%s'\nDISTRIB_TARGET='x86/64'\n" "$OPENWRT_VERSION" > "$WORK/openwrt_release"
if [ -z "$VALIDATION_SOURCE_VERSION" ]; then
  if [ "$APP_VERSION" = 0.7.11 ]; then
    VALIDATION_SOURCE_VERSION=0.7.10
    VALIDATION_SOURCE_PROTOCOL=1
  else
    VALIDATION_SOURCE_VERSION=0.7.11
    VALIDATION_SOURCE_PROTOCOL=2
  fi
fi
[ -n "$VALIDATION_SOURCE_PROTOCOL" ] || VALIDATION_SOURCE_PROTOCOL=2
PREMIER_ROUTER_HOST_TEST=1 PR_USIGN_BIN="$USIGN_BIN" \
  PR_OPENWRT_RELEASE_FILE="$WORK/openwrt_release" \
  sh -c '. "$1"; pr_manifest_validate "$2" "$3" "$4" "$5"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  "$MANIFEST" "$EXPECTED_RELEASE_KEY_ID" "$VALIDATION_SOURCE_VERSION" \
  "$VALIDATION_SOURCE_PROTOCOL" || fail "manifest semantic validation failed"

jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg tag "vpn-panel-v$APP_VERSION" --arg key "$EXPECTED_RELEASE_KEY_ID" '
  .schema_version == 2 and .update_protocol == 2 and .channel == "stable" and
  .app_version == $version and .package_version == $package and
  .release_tag == $tag and .signing_key_id == $key and .source_dirty == false and
  (.source_commit | test("^[0-9a-f]{40}$")) and
  (.transitions | map(.source_version) | index("0.7.7") | not) and
  ([.packages[].install_order] == [1,2,3]) and
  ([.packages[].name] == ["premier-router-core","luci-app-premier-router","premier-router-setup"])
' "$MANIFEST" >/dev/null || fail "manifest authority fields mismatch"
MANIFEST_COMMIT="$(jq -r .source_commit "$MANIFEST")"
[ -z "$EXPECTED_SOURCE_COMMIT" ] || [ "$MANIFEST_COMMIT" = "$EXPECTED_SOURCE_COMMIT" ] ||
  fail "manifest source commit differs from expected commit"
jq -e --arg version "$APP_VERSION" --arg tag "vpn-panel-v$APP_VERSION" \
  --arg hash "$(sha256sum "$MANIFEST" | awk '{print $1}')" \
  --arg key "$EXPECTED_RELEASE_KEY_ID" '
  .schema_version == 1 and .channel == "stable" and .target_version == $version and
  .release_tag == $tag and .manifest_filename == "router-release-manifest.json" and
  .manifest_sha256 == $hash and .signing_key_id == $key
' "$POINTER" >/dev/null || fail "stable pointer does not pin the exact manifest"
jq -e --arg version "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg commit "$MANIFEST_COMMIT" --arg key "$EXPECTED_RELEASE_KEY_ID" '
  .schema_version == 1 and .app_version == $version and .package_version == $package and
  .source_commit == $commit and .source_dirty == false and .signing_key_id == $key and
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
grep -Fqx "SOURCE_COMMIT=$MANIFEST_COMMIT" "$WORK/core/usr/share/premier-router/build-info" ||
  fail "core IPK source commit mismatch"
grep -Fqx 'SOURCE_DIRTY=false' "$WORK/core/usr/share/premier-router/build-info" ||
  fail "core IPK dirty provenance"

if [ "$APP_VERSION" = 0.7.11 ]; then
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
fi

image_count="$(find "$RELEASE_DIR" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" | wc -l | tr -d ' ')"
if [ "$REQUIRE_IMAGES" = 1 ] && [ "$image_count" -lt 3 ]; then
  fail "release requires x86, RD23 stock, and RD23 ubootmod image archives"
fi
find "$RELEASE_DIR" -maxdepth 1 -type f -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" |
  while IFS= read -r archive; do
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
      .openwrt_version == $version and .updater_protocol == 2
    ' "$WORK/image.provenance" >/dev/null || fail "image provenance mismatch"
  done

if [ "$STRICT_RELEASE" = 1 ]; then
  case "$EXPECTED_RELEASE_KEY_ID" in test-*|dev-*|development-*) fail "strict release refuses a development key ID" ;; esac
  grep -Eqi 'development|test key' "$RELEASE_PUBLIC_KEY" && fail "strict release refuses a development public key"
  grep -Eqi 'development|test key|test-[0-9a-f]+' "$RELEASE_DIR/install-router-ui-release.sh" "$RELEASE_DIR/rescue-router-ui.sh" &&
    fail "strict release found development trust material in public scripts"
  [ -n "$EXPECTED_SOURCE_COMMIT" ] || fail "strict release requires EXPECTED_SOURCE_COMMIT"
  git -C "$ROOT_DIR" merge-base --is-ancestor "$EXPECTED_SOURCE_COMMIT" origin/main ||
    fail "release source commit is not contained in origin/main"
fi

printf 'staged release validation passed: %s (%s assets, %s images)\n' \
  "$RELEASE_DIR" "$(wc -l < "$WORK/files.actual" | tr -d ' ')" "$image_count"
