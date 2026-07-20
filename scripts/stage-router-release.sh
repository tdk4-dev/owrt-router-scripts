#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$APP_VERSION-${PKG_RELEASE:-1}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/dist}"
IPK_DIR="${IPK_DIR:-$OUT_ROOT/ipk}"
RELEASE_DIR="${RELEASE_DIR:-$OUT_ROOT/release-v$APP_VERSION}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
SOURCE_DIRTY="${SOURCE_DIRTY:-}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT")}"
RELEASE_PUBLIC_KEY="${RELEASE_PUBLIC_KEY:-$ROOT_DIR/release/keys/router-ui-production.pub}"
RELEASE_KEY_ID="${RELEASE_KEY_ID:-$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.key-id" | tr -d '\r\n')}"
SIGNING_KEY="${SIGNING_KEY:-}"
USIGN_BIN="${USIGN_BIN:-usign}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-stage.XXXXXX")"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for tool in awk cp date find grep gzip jq sed sha256sum sort tar wc "$USIGN_BIN"; do need "$tool"; done

[ "$APP_VERSION" = 0.7.11 ] || fail "stage script is scoped to Router UI 0.7.11"
printf '%s' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' ||
  fail "SOURCE_COMMIT must be an exact commit"
if [ -z "$SOURCE_DIRTY" ]; then
  if [ -n "$(git -C "$ROOT_DIR" status --short)" ]; then SOURCE_DIRTY=true; else SOURCE_DIRTY=false; fi
fi
case "$SOURCE_DIRTY" in true|false) ;; *) fail "SOURCE_DIRTY must be true or false" ;; esac
[ -s "$SIGNING_KEY" ] || fail "SIGNING_KEY is required"
[ -s "$RELEASE_PUBLIC_KEY" ] || fail "release public key is missing"
[ "$("$USIGN_BIN" -F -s "$SIGNING_KEY")" = "$("$USIGN_BIN" -F -p "$RELEASE_PUBLIC_KEY")" ] ||
  fail "signing key and release public key do not match"
if [ "$STRICT_RELEASE" = 1 ]; then
  [ "$SOURCE_DIRTY" = false ] || fail "strict release refuses dirty source"
  case "$RELEASE_KEY_ID" in test-*|dev-*|development-*) fail "strict release refuses a development key ID" ;; esac
  grep -qi 'development\|test key' "$RELEASE_PUBLIC_KEY" &&
    fail "strict release refuses a development public key"
  [ "$RELEASE_KEY_ID" = "$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.key-id" | tr -d '\r\n')" ] &&
    [ "$($USIGN_BIN -F -p "$RELEASE_PUBLIC_KEY")" = "$(sed -n '1p' "$ROOT_DIR/release/keys/router-ui-production.fingerprint" | tr -d '\r\n')" ] ||
    fail "strict release requires the committed production public key and key ID"
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
  awk -v key_id="$RELEASE_KEY_ID" -v key_comment="$key_comment" -v key_data="$key_data" '
    /^TRUSTED_KEY_ID=/ { print "TRUSTED_KEY_ID=\047" key_id "\047"; next }
    /^TRUSTED_KEY_COMMENT=/ { print "TRUSTED_KEY_COMMENT=\047" key_comment "\047"; next }
    /^TRUSTED_KEY_DATA=/ { print "TRUSTED_KEY_DATA=\047" key_data "\047"; next }
    { print }
  ' "$src" > "$dst"
}
render_trust_script "$ROOT_DIR/rescue-router-ui.sh" "$RELEASE_DIR/rescue-router-ui.sh"
chmod 755 "$RELEASE_DIR/router-candidate-validator" \
  "$RELEASE_DIR/router-update-supervisor" \
  "$RELEASE_DIR/router-update-lib.sh" \
  "$RELEASE_DIR/install-router-ui-release.sh" \
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
RESCUE_JSON="$(asset_object "$RELEASE_DIR/rescue-router-ui.sh" 1)"
STORAGE_GEOMETRY_JSON="$(asset_object "$RELEASE_DIR/rd23-storage-geometry.json" 1)"

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

TRANSITIONS_JSON='[
  {"source_version":"0.5.1","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.5.2","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.6.0","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.0","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.1","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.2","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.3","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.4","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.5","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.6","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.8","source_protocol":1,"mode":"rescue"},
  {"source_version":"0.7.9","source_protocol":1,"mode":"legacy-bridge-or-rescue"},
  {"source_version":"0.7.10","source_protocol":1,"mode":"legacy-bridge-or-rescue"},
  {"source_version":"0.7.11","source_protocol":2,"mode":"package-v2"}
]'

MANIFEST="$RELEASE_DIR/router-release-manifest.json"
jq -n \
  --arg channel stable \
  --arg app_version "$APP_VERSION" \
  --arg package_version "$PKG_VERSION" \
  --arg release_tag "vpn-panel-v$APP_VERSION" \
  --arg source_commit "$SOURCE_COMMIT" \
  --argjson source_dirty "$SOURCE_DIRTY" \
  --argjson source_date_epoch "$SOURCE_DATE_EPOCH" \
  --arg generated_at "$GENERATED_AT" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --argjson packages "$PACKAGES_JSON" \
  --argjson validator "$VALIDATOR_JSON" \
  --argjson supervisor "$SUPERVISOR_JSON" \
  --argjson update_library "$LIB_JSON" \
  --argjson compat "$COMPAT_JSON" \
  --argjson standalone_installer "$INSTALLER_JSON" \
  --argjson rescue "$RESCUE_JSON" \
  --argjson storage_geometry "$STORAGE_GEOMETRY_JSON" \
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
    packages:$packages,
    candidate_validator:$validator,
    transaction_supervisor:$supervisor,
    update_library:$update_library,
    compatibility:{status_0_7_9:$compat},
    standalone_installer:$standalone_installer,
    rescue:$rescue,
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

POINTER="$RELEASE_DIR/stable-channel.json"
jq -n \
  --arg channel stable \
  --arg target_version "$APP_VERSION" \
  --arg release_tag "vpn-panel-v$APP_VERSION" \
  --arg manifest_filename router-release-manifest.json \
  --arg manifest_sha256 "$(sha256sum "$MANIFEST" | awk '{print $1}')" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  '{schema_version:1,channel:$channel,target_version:$target_version,
    release_tag:$release_tag,manifest_filename:$manifest_filename,
    manifest_sha256:$manifest_sha256,signing_key_id:$signing_key_id}' |
  jq -S . > "$POINTER"
"$USIGN_BIN" -S -m "$POINTER" -s "$SIGNING_KEY" \
  -x "$RELEASE_DIR/stable-channel.json.sig"

BUNDLE_ROOT="$STAGE/luci-vpn-ui"
BRIDGE="$BUNDLE_ROOT/bridge"
mkdir -p "$BRIDGE"
cp "$ROOT_DIR/luci-vpn-ui/VERSION" "$BUNDLE_ROOT/VERSION"
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
create_repro_tar "$STAGE" "$RELEASE_DIR/luci-vpn-ui.tar.gz" luci-vpn-ui

for file in \
  luci-vpn-ui.tar.gz \
  install-router-ui-release.sh \
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
  --argjson canonical_ipks "$IPK_PROVENANCE" \
  --argjson images "$IMAGES_JSON" \
  '{schema_version:1,app_version:$app_version,package_version:$package_version,
    source_commit:$source_commit,source_dirty:$source_dirty,
    source_date_epoch:$source_date_epoch,signing_key_id:$signing_key_id,
    canonical_ipks:$canonical_ipks,derived_images:$images}' |
  jq -S . > "$PROVENANCE"
"$USIGN_BIN" -S -m "$PROVENANCE" -s "$SIGNING_KEY" \
  -x "$RELEASE_DIR/release-provenance.json.sig"

(
  cd "$RELEASE_DIR"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print |
    sed 's#^\./##' | sort |
    while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS
)
printf 'Staged flat Router UI %s release at %s\n' "$APP_VERSION" "$RELEASE_DIR"
