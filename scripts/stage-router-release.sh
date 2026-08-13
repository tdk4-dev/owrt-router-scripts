#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'staging:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION" | tr -d '\r\n')"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/dist}"
IPK_DIR="${IPK_DIR:-$OUT_ROOT/ipk}"
FEED_DIR="${FEED_DIR:-$OUT_ROOT/opkg-feed}"
INSTALLED_SET_DIR="${INSTALLED_SET_DIR:-$OUT_ROOT/installed-package-set}"
RELEASE_DIR="${RELEASE_DIR:-$OUT_ROOT/release-v$APP_VERSION}"
case "$APP_VERSION" in *-rc.*) DEFAULT_RELEASE_CHANNEL=candidate ;; *) DEFAULT_RELEASE_CHANNEL=stable ;; esac
RELEASE_CHANNEL="${RELEASE_CHANNEL:-$DEFAULT_RELEASE_CHANNEL}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DIRTY="${SOURCE_DIRTY:-}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT")}"
USIGN_BIN="${USIGN_BIN:-usign}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-stage.XXXXXX")"
ROUTER_UI_RELEASE_ROOT="$ROOT_DIR"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for tool in awk cmp cp date find grep gzip jq sed sha256sum sort tar wc "$USIGN_BIN"; do need "$tool"; done

[ "${APP_VERSION%%-rc.*}" = 0.7.11 ] || fail "stage script is scoped to Router UI 0.7.11"
case "$RELEASE_CHANNEL" in candidate|stable) ;; *) fail "unsupported release channel: $RELEASE_CHANNEL" ;; esac
printf '%s' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' ||
  fail "SOURCE_COMMIT must be an exact commit"
if [ -n "$(git -C "$ROOT_DIR" status --short)" ]; then ACTUAL_SOURCE_DIRTY=true; else ACTUAL_SOURCE_DIRTY=false; fi
if [ "$STRICT_RELEASE" = 1 ] && [ -n "$SOURCE_DIRTY" ] && [ "$SOURCE_DIRTY" != "$ACTUAL_SOURCE_DIRTY" ]; then
  fail "SOURCE_DIRTY disagrees with the checkout state"
fi
SOURCE_DIRTY="${SOURCE_DIRTY:-$ACTUAL_SOURCE_DIRTY}"
case "$SOURCE_DIRTY" in true|false) ;; *) fail "SOURCE_DIRTY must be true or false" ;; esac
pr_require_active_signing_key || exit 1
if [ "$STRICT_RELEASE" = 1 ]; then
  [ "$SOURCE_DIRTY" = false ] || fail "strict release refuses dirty source"
  case "$RELEASE_KEY_ID" in test-*|dev-*|development-*) fail "strict release refuses a development key ID" ;; esac
  grep -qi 'development\|test key' "$RELEASE_PUBLIC_KEY" &&
    fail "strict release refuses a development public key"
  pr_require_committed_registry || exit 1
fi

for package in $PROJECT_PACKAGES; do
  [ -s "$IPK_DIR/${package}_${PKG_VERSION}_all.ipk" ] ||
    fail "canonical IPK is missing: $package"
done
[ -s "$IPK_DIR/router-ui-packages.txt" ] || fail "canonical package manifest is missing"

rm -rf "$RELEASE_DIR"
mkdir -p "$OUT_ROOT" "$RELEASE_DIR"
for package in $PROJECT_PACKAGES; do
  cp "$IPK_DIR/${package}_${PKG_VERSION}_all.ipk" "$RELEASE_DIR/"
done
cp "$IPK_DIR/router-ui-packages.txt" "$RELEASE_DIR/router-ui-packages.txt"
cp "$RELEASE_PUBLIC_KEY" "$RELEASE_DIR/$RELEASE_KEY_ID.pub"
printf '%s\n' "$RELEASE_KEY_ID" > "$RELEASE_DIR/release-signing-key-id"
printf '%s\n' "$RELEASE_KEY_FINGERPRINT" > "$RELEASE_DIR/$RELEASE_KEY_ID.fingerprint"
cp "$ROOT_DIR/release/keys/trusted-keys.json" "$RELEASE_DIR/trusted-keys.json"
jq --arg target "$APP_VERSION" --arg package "$PKG_VERSION" \
  --arg channel "$RELEASE_CHANNEL" \
  '.target = $target | .package_version = $package | .release_channel = $channel' \
  "$ROOT_DIR/release/transition-matrix.json" > \
  "$RELEASE_DIR/historical-rescue-support-matrix.json"
cp "$ROOT_DIR/docs/historical-rescue-support-matrix.md" "$RELEASE_DIR/historical-rescue-support-matrix.md"
cp "$ROOT_DIR/docs/ordinary-user-ipk-installation.md" "$RELEASE_DIR/INSTALLATION-RECOVERY.md"
cp "$ROOT_DIR/luci-vpn-ui/RELEASE_NOTES.md" "$RELEASE_DIR/RELEASE-NOTES.md"

for file in installed-manifest.json installed-manifest.json.sig; do
  [ -s "$INSTALLED_SET_DIR/$file" ] || fail "installed package-set artifact is missing: $file"
  cp "$INSTALLED_SET_DIR/$file" "$RELEASE_DIR/$file"
done
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$RELEASE_DIR/installed-manifest.json" \
  -x "$RELEASE_DIR/installed-manifest.json.sig" || fail "installed package manifest signature is invalid"

for file in Packages Packages.gz Packages.sig SHA256SUMS feed-provenance.json feed-provenance.json.sig; do
  [ -s "$FEED_DIR/$file" ] || fail "signed candidate feed artifact is missing: $file"
done
for package in $PROJECT_PACKAGES; do
  cmp -s "$IPK_DIR/${package}_${PKG_VERSION}_all.ipk" \
    "$FEED_DIR/${package}_${PKG_VERSION}_all.ipk" || fail "feed package differs from canonical bytes: $package"
done
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$FEED_DIR/Packages" \
  -x "$FEED_DIR/Packages.sig" || fail "candidate feed signature is invalid"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$FEED_DIR/feed-provenance.json" \
  -x "$FEED_DIR/feed-provenance.json.sig" || fail "candidate feed provenance signature is invalid"
DETECTED_FEED_CHANNEL="$(jq -er '.channel' "$FEED_DIR/feed-provenance.json")"
[ "$DETECTED_FEED_CHANNEL" = "$RELEASE_CHANNEL" ] || fail "feed release channel mismatch"
(cd "$FEED_DIR" && sha256sum -c SHA256SUMS >/dev/null) || fail "candidate feed checksums are invalid"

CORE_ROOT="$STAGE/core-root"
mkdir -p "$CORE_ROOT"
tar -xzOf "$IPK_DIR/premier-router-core_${PKG_VERSION}_all.ipk" ./data.tar.gz |
  tar -xzf - -C "$CORE_ROOT"
cp "$CORE_ROOT/usr/libexec/premier-router/candidate-validator" \
  "$RELEASE_DIR/router-candidate-validator"
cp "$CORE_ROOT/usr/sbin/vpn-ui-update" "$RELEASE_DIR/router-update-supervisor"
cp "$CORE_ROOT/usr/libexec/premier-router/update-lib.sh" \
  "$RELEASE_DIR/router-update-lib.sh"
cp "$ROOT_DIR/release/compat/0.7.9/_35_vpn.js" \
  "$RELEASE_DIR/0.7.9-_35_vpn.js"
cp "$CORE_ROOT/usr/sbin/install-router-ui-release" \
  "$RELEASE_DIR/install-router-ui-release.sh"

render_trust_script() {
  local src="$1" dst="$2" key_comment key_data
  key_comment="$(sed -n '1p' "$RELEASE_PUBLIC_KEY" | tr -d '\r\n')"
  key_data="$(sed -n '2p' "$RELEASE_PUBLIC_KEY" | tr -d '\r\n')"
  printf '%s' "$RELEASE_KEY_ID" | grep -Eq '^[A-Za-z0-9._-]+$' ||
    fail "release key ID is malformed"
  printf '%s' "$key_comment" | grep -Eq '^untrusted comment: [A-Za-z0-9 ._:/+-]+$' ||
    fail "release public key comment is unsafe"
  printf '%s' "$key_data" | grep -Eq '^RW[A-Za-z0-9+/=]+$' ||
    fail "release public key data is malformed"
  awk -v key_id="$RELEASE_KEY_ID" -v fingerprint="$RELEASE_KEY_FINGERPRINT" \
    -v key_comment="$key_comment" -v key_data="$key_data" \
    -v app_version="$APP_VERSION" -v package_version="$PKG_VERSION" '
    /^TARGET_VERSION=/ { print "TARGET_VERSION=" app_version; next }
    /^TARGET_APP_VERSION=/ { print "TARGET_APP_VERSION=\047" app_version "\047"; next }
    /^TARGET_PACKAGE_VERSION=/ { print "TARGET_PACKAGE_VERSION=\047" package_version "\047"; next }
    /^TRUSTED_KEY_ID=/ { print "TRUSTED_KEY_ID=\047" key_id "\047"; next }
    /^TRUSTED_KEY_FINGERPRINT=/ { print "TRUSTED_KEY_FINGERPRINT=\047" fingerprint "\047"; next }
    /^TRUSTED_KEY_COMMENT=/ { print "TRUSTED_KEY_COMMENT=\047" key_comment "\047"; next }
    /^TRUSTED_KEY_DATA=/ { print "TRUSTED_KEY_DATA=\047" key_data "\047"; next }
    { print }
  ' "$src" > "$dst"
}
render_trust_script "$ROOT_DIR/rescue-router-ui.sh" "$RELEASE_DIR/rescue-router-ui.sh"
render_trust_script "$ROOT_DIR/bootstrap-router-ui-ipk-install.sh" \
  "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh"
chmod 755 "$RELEASE_DIR/router-candidate-validator" \
  "$RELEASE_DIR/router-update-supervisor" \
  "$RELEASE_DIR/router-update-lib.sh" \
  "$RELEASE_DIR/install-router-ui-release.sh" \
  "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh" \
  "$RELEASE_DIR/rescue-router-ui.sh"

printf '%s\n' "$APP_VERSION" > "$RELEASE_DIR/vpn-ui-version.txt"
cp "$ROOT_DIR/luci-vpn-ui/RELEASE_NOTES.md" "$RELEASE_DIR/vpn-ui-changelog.txt"
cp "$ROOT_DIR/release/rd23-storage-geometry.json" \
  "$RELEASE_DIR/rd23-storage-geometry.json"
if date -u -r "$SOURCE_DATE_EPOCH" '+%B %d, %Y' >/dev/null 2>&1; then
  date -u -r "$SOURCE_DATE_EPOCH" '+%B %d, %Y' > "$RELEASE_DIR/vpn-ui-release-date.txt"
  GENERATED_AT="$(date -u -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
else
  GENERATED_AT="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
  date -u -d "@$SOURCE_DATE_EPOCH" '+%B %d, %Y' > "$RELEASE_DIR/vpn-ui-release-date.txt"
fi

create_repro_tar() {
  local source="$1" output="$2" member="$3"
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 \
      --numeric-owner -czf "$output" -C "$source" "$member"
  else
    normalized="$(date -u -r "$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S')"
    find "$source/$member" -exec env TZ=UTC touch -h -t "$normalized" {} +
    COPYFILE_DISABLE=1 tar --format ustar --no-xattrs --no-mac-metadata \
      --owner=0 --group=0 --numeric-owner -czf "$output" -C "$source" "$member"
  fi
}

FEED_ARCHIVE="$RELEASE_DIR/premier-router-opkg-feed-$APP_VERSION.tar.gz"
create_repro_tar "$FEED_DIR" "$FEED_ARCHIVE" .

find "$OUT_ROOT" -maxdepth 1 -type f \
  -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" |
  sort | while IFS= read -r image; do
    cp "$image" "$RELEASE_DIR/"
    [ ! -f "$image.sha256" ] || cp "$image.sha256" "$RELEASE_DIR/"
  done

ipk_control() {
  tar -xzOf "$1" ./control.tar.gz | tar -xzOf - ./control
}
package_json() {
  local package order file
  package="$1"
  order="$2"
  file="$RELEASE_DIR/${package}_${PKG_VERSION}_all.ipk"
  local control_name control_version control_arch
  control_name="$(ipk_control "$file" | sed -n 's/^Package: //p')"
  control_version="$(ipk_control "$file" | sed -n 's/^Version: //p')"
  control_arch="$(ipk_control "$file" | sed -n 's/^Architecture: //p')"
  [ "$control_name" = "$package" ] && [ "$control_version" = "$PKG_VERSION" ] &&
    [ "$control_arch" = all ] || fail "IPK control metadata mismatch: $package"
  jq -n \
    --arg name "$package" \
    --arg filename "$(basename "$file")" \
    --arg version "$PKG_VERSION" \
    --arg architecture all \
    --arg sha256 "$(sha256sum "$file" | awk '{print $1}')" \
    --argjson size "$(wc -c < "$file" | tr -d ' ')" \
    --argjson install_order "$order" \
    '{name:$name,filename:$filename,version:$version,architecture:$architecture,
      size:$size,sha256:$sha256,install_order:$install_order}'
}
PACKAGES_JSON="$(
  package_json premier-router-core 1
  package_json luci-app-premier-router 2
  package_json premier-router-setup 3
)"
PACKAGES_JSON="$(printf '%s\n' "$PACKAGES_JSON" | jq -s 'sort_by(.install_order)')"

asset_object() {
  local file="$1" protocol="$2"
  jq -n \
    --arg filename "$(basename "$file")" \
    --arg sha256 "$(sha256sum "$file" | awk '{print $1}')" \
    --argjson size "$(wc -c < "$file" | tr -d ' ')" \
    --argjson protocol "$protocol" \
    '{filename:$filename,size:$size,sha256:$sha256,protocol:$protocol}'
}
VALIDATOR_JSON="$(asset_object "$RELEASE_DIR/router-candidate-validator" 1)"
SUPERVISOR_JSON="$(asset_object "$RELEASE_DIR/router-update-supervisor" 2)"
LIB_JSON="$(asset_object "$RELEASE_DIR/router-update-lib.sh" 1)"
COMPAT_JSON="$(asset_object "$RELEASE_DIR/0.7.9-_35_vpn.js" 1)"
INSTALLER_JSON="$(asset_object "$RELEASE_DIR/install-router-ui-release.sh" 2)"
BOOTSTRAP_JSON="$(asset_object "$RELEASE_DIR/bootstrap-router-ui-ipk-install.sh" 1)"
RESCUE_JSON="$(asset_object "$RELEASE_DIR/rescue-router-ui.sh" 1)"
STORAGE_GEOMETRY_JSON="$(asset_object "$RELEASE_DIR/rd23-storage-geometry.json" 1)"
FEED_JSON="$(asset_object "$FEED_ARCHIVE" 1)"
INSTALLED_MANIFEST_JSON="$(asset_object "$RELEASE_DIR/installed-manifest.json" 1)"

IMAGES_FILE="$STAGE/images.jsonl"
: > "$IMAGES_FILE"
find "$RELEASE_DIR" -maxdepth 1 -type f \
  -name "premier-router-$APP_VERSION-openwrt-$OPENWRT_VERSION-*.tar.gz" |
  sort | while IFS= read -r image; do
    name="$(basename "$image")"
    case "$name" in
      *x86-64*) target='x86/64'; profile=generic ;;
      *xiaomi-ax3000t-stock*) target='mediatek/filogic'; profile=xiaomi_mi-router-ax3000t ;;
      *xiaomi-ax3000t-ubootmod*) target='mediatek/filogic'; profile=xiaomi_mi-router-ax3000t-ubootmod ;;
      *) target=unknown; profile=unknown ;;
    esac
    provenance_member="$(tar -tzf "$image" | awk '/\/image-provenance\.json$/ && !found {print; found=1}')"
    [ -n "$provenance_member" ] || fail "image archive lacks storage provenance: $name"
    storage="$(tar -xOzf "$image" "$provenance_member" | jq '{storage_profile,
      writable_backing_kib,expected_ubifs_df_total_kib,x86_rootfs_partsize_kib,
      rd23_storage_layout}')"
    jq -n --arg filename "$name" --arg target "$target" --arg profile "$profile" \
      --arg sha256 "$(sha256sum "$image" | awk '{print $1}')" \
      --argjson size "$(wc -c < "$image" | tr -d ' ')" \
      --argjson storage "$storage" \
      '{filename:$filename,target:$target,profile:$profile,size:$size,sha256:$sha256,
        storage:$storage}' \
      >> "$IMAGES_FILE"
  done
if [ -s "$IMAGES_FILE" ]; then
  IMAGES_JSON="$(jq -s '.' "$IMAGES_FILE")"
else
  IMAGES_JSON='[]'
fi

if [ "$RELEASE_CHANNEL" = candidate ]; then
  PROTOCOL2_TRANSITIONS='[{"source_version":"0.7.11-rc.5","source_protocol":2,"mode":"package-v2-rc"},{"source_version":"0.7.11-rc.6","source_protocol":2,"mode":"package-v2-rc"},{"source_version":"0.7.11-rc.7","source_protocol":2,"mode":"package-v2-rc"}]'
else
  PROTOCOL2_TRANSITIONS='[{"source_version":"0.7.11-rc.9","source_protocol":2,"mode":"package-v2-rc"}]'
fi
TRANSITIONS_JSON="$(jq --argjson protocol2 "$PROTOCOL2_TRANSITIONS" '[.baselines[] | select(.published_release == true) |
  {source_version:.version,source_protocol:1,
   mode:(if .adapter == "none" then "rescue" else "compatibility-adapter" end)}] + $protocol2' \
  "$ROOT_DIR/release/transition-matrix.json")"

MANIFEST="$RELEASE_DIR/router-release-manifest.json"
jq -n \
  --arg channel "$RELEASE_CHANNEL" \
  --arg app_version "$APP_VERSION" \
  --arg package_version "$PKG_VERSION" \
  --arg release_tag "vpn-panel-v$APP_VERSION" \
  --arg source_commit "$SOURCE_COMMIT" \
  --argjson source_dirty "$SOURCE_DIRTY" \
  --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
  --arg generated_at "$GENERATED_AT" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" \
  --argjson packages "$PACKAGES_JSON" \
  --argjson validator "$VALIDATOR_JSON" \
  --argjson supervisor "$SUPERVISOR_JSON" \
  --argjson update_library "$LIB_JSON" \
  --argjson compat "$COMPAT_JSON" \
  --argjson standalone_installer "$INSTALLER_JSON" \
  --argjson initial_ipk_bootstrap "$BOOTSTRAP_JSON" \
  --argjson rescue "$RESCUE_JSON" \
  --argjson storage_geometry "$STORAGE_GEOMETRY_JSON" \
  --argjson package_feed "$FEED_JSON" \
  --argjson installed_manifest "$INSTALLED_MANIFEST_JSON" \
  --argjson transitions "$TRANSITIONS_JSON" \
  --argjson images "$IMAGES_JSON" \
  '{
    schema_version:2,
    update_protocol:2,
    channel:$channel,
    app_version:$app_version,
    package_version:$package_version,
    release_tag:$release_tag,
    source_commit:$source_commit,
    source_dirty:$source_dirty,
    source_date_epoch:$source_date_epoch,
    generated_at:$generated_at,
    supported_openwrt:{min:"24.10.0",max:"24.10.99"},
    supported_targets:["x86/64","mediatek/filogic"],
    minimum_updater_protocol:2,
    transitions:$transitions,
    signing_key_id:$signing_key_id,
    signing_key_fingerprint:$signing_key_fingerprint,
    packages:$packages,
    candidate_validator:$validator,
    transaction_supervisor:$supervisor,
    update_library:$update_library,
    compatibility:{status_0_7_9:$compat},
    standalone_installer:$standalone_installer,
    initial_ipk_bootstrap:$initial_ipk_bootstrap,
    rescue:$rescue,
    package_feed:$package_feed,
    installed_package_manifest:$installed_manifest,
    rd23_storage_geometry:$storage_geometry,
    compatibility_transport:{
      filename:"luci-vpn-ui.tar.gz",
      hash_authority:"legacy sha256 sidecar",
      self_hash_excluded:true,
      reason:"the bundle embeds this signed manifest, so a self hash is impossible"
    },
    images:$images
  }' | jq -S . > "$MANIFEST"
"$USIGN_BIN" -S -m "$MANIFEST" -s "$SIGNING_KEY" \
  -x "$RELEASE_DIR/router-release-manifest.json.sig"

POINTER="$RELEASE_DIR/$RELEASE_CHANNEL-channel.json"
jq -n \
  --arg channel "$RELEASE_CHANNEL" \
  --arg target_version "$APP_VERSION" \
  --arg release_tag "vpn-panel-v$APP_VERSION" \
  --arg manifest_filename router-release-manifest.json \
  --arg manifest_sha256 "$(sha256sum "$MANIFEST" | awk '{print $1}')" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" \
  '{schema_version:1,channel:$channel,target_version:$target_version,
    release_tag:$release_tag,manifest_filename:$manifest_filename,
    manifest_sha256:$manifest_sha256,signing_key_id:$signing_key_id,
    signing_key_fingerprint:$signing_key_fingerprint}' |
  jq -S . > "$POINTER"
"$USIGN_BIN" -S -m "$POINTER" -s "$SIGNING_KEY" \
  -x "$RELEASE_DIR/$RELEASE_CHANNEL-channel.json.sig"

BUNDLE_ROOT="$STAGE/luci-vpn-ui"
BRIDGE="$BUNDLE_ROOT/bridge"
mkdir -p "$BRIDGE"
cp "$ROOT_DIR/luci-vpn-ui/VERSION" "$BUNDLE_ROOT/VERSION"
cp "$ROOT_DIR/luci-vpn-ui/PACKAGE_VERSION" "$BUNDLE_ROOT/PACKAGE_VERSION"
cp "$ROOT_DIR/luci-vpn-ui/install.sh" "$BUNDLE_ROOT/install.sh"
chmod 755 "$BUNDLE_ROOT/install.sh"
cp "$MANIFEST" "$BRIDGE/router-release-manifest.json"
cp "$RELEASE_DIR/router-release-manifest.json.sig" "$BRIDGE/"
cp "$RELEASE_PUBLIC_KEY" "$BRIDGE/trusted-release.pub"
printf '%s\n' "$RELEASE_KEY_ID" > "$BRIDGE/release-key-id"
cp "$RELEASE_DIR/router-candidate-validator" "$BRIDGE/"
cp "$RELEASE_DIR/router-update-supervisor" "$BRIDGE/vpn-ui-update"
cp "$RELEASE_DIR/router-update-lib.sh" "$BRIDGE/update-lib.sh"
cp "$RELEASE_DIR/0.7.9-_35_vpn.js" "$BRIDGE/"
for package in $PROJECT_PACKAGES; do
  cp "$RELEASE_DIR/${package}_${PKG_VERSION}_all.ipk" "$BRIDGE/"
done
find "$BUNDLE_ROOT" -type d -exec chmod 755 {} \;
find "$BUNDLE_ROOT" -type f -exec chmod 644 {} \;
chmod 755 "$BUNDLE_ROOT/install.sh" "$BRIDGE/router-candidate-validator" \
  "$BRIDGE/vpn-ui-update" "$BRIDGE/update-lib.sh"

create_repro_tar "$STAGE" "$RELEASE_DIR/luci-vpn-ui.tar.gz" luci-vpn-ui

for file in \
  luci-vpn-ui.tar.gz \
  install-router-ui-release.sh \
  bootstrap-router-ui-ipk-install.sh \
  rescue-router-ui.sh
do
  (cd "$RELEASE_DIR" && sha256sum "$file" > "$file.sha256")
done

PROVENANCE="$RELEASE_DIR/release-provenance.json"
IPK_PROVENANCE="$(
  for package in $PROJECT_PACKAGES; do
    file="$RELEASE_DIR/${package}_${PKG_VERSION}_all.ipk"
    jq -n --arg filename "$(basename "$file")" \
      --arg sha256 "$(sha256sum "$file" | awk '{print $1}')" \
      --argjson size "$(wc -c < "$file" | tr -d ' ')" \
      '{filename:$filename,size:$size,sha256:$sha256}'
  done | jq -s .
)"
jq -n \
  --arg app_version "$APP_VERSION" \
  --arg package_version "$PKG_VERSION" \
  --arg source_commit "$SOURCE_COMMIT" \
  --argjson source_dirty "$SOURCE_DIRTY" \
  --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" \
  --argjson canonical_ipks "$IPK_PROVENANCE" \
  --argjson images "$IMAGES_JSON" \
  '{schema_version:1,app_version:$app_version,package_version:$package_version,
    source_commit:$source_commit,source_dirty:$source_dirty,
    source_date_epoch:$source_date_epoch,signing_key_id:$signing_key_id,
    signing_key_fingerprint:$signing_key_fingerprint,
    canonical_ipks:$canonical_ipks,derived_images:$images}' |
  jq -S . > "$PROVENANCE"
"$USIGN_BIN" -S -m "$PROVENANCE" -s "$SIGNING_KEY" \
  -x "$RELEASE_DIR/release-provenance.json.sig"

if [ -n "${FACTORY_PRODUCT_VERSION:-}" ]; then
  RELEASE_DIR="$RELEASE_DIR" \
    FACTORY_PRODUCT_VERSION="$FACTORY_PRODUCT_VERSION" \
    FACTORY_RELEASE_PUBLISHED_AT="${FACTORY_RELEASE_PUBLISHED_AT:-$GENERATED_AT}" \
    FACTORY_REQUIRED_PERSISTENT_BYTES="${FACTORY_REQUIRED_PERSISTENT_BYTES:-2097152}" \
    FACTORY_REQUIRED_TMP_BYTES="${FACTORY_REQUIRED_TMP_BYTES:-1131520}" \
    USIGN_BIN="$USIGN_BIN" \
    "$ROOT_DIR/scripts/stage-factory-schema2-contract.sh"
fi

(
  cd "$RELEASE_DIR"
  find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -print |
    sed 's#^\./##' | sort |
    while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS
)
"$USIGN_BIN" -S -m "$RELEASE_DIR/SHA256SUMS" -s "$SIGNING_KEY" \
  -x "$RELEASE_DIR/SHA256SUMS.sig"
printf 'Staged flat Router UI %s release at %s\n' "$APP_VERSION" "$RELEASE_DIR"
