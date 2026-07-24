#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/dist/release-v0.7.11}"
FACTORY_PRODUCT_VERSION="${FACTORY_PRODUCT_VERSION:-}"
FACTORY_RELEASE_PUBLISHED_AT="${FACTORY_RELEASE_PUBLISHED_AT:-}"
FACTORY_REQUIRED_PERSISTENT_BYTES="${FACTORY_REQUIRED_PERSISTENT_BYTES:-2097152}"
FACTORY_REQUIRED_TMP_BYTES="${FACTORY_REQUIRED_TMP_BYTES:-1048576}"
FACTORY_MINIMUM_VERSION="${FACTORY_MINIMUM_VERSION:-0.2.0-dev1}"
USIGN_BIN="${USIGN_BIN:-usign}"
ROUTER_UI_RELEASE_ROOT="$ROOT_DIR"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for tool in awk cp date find grep jq sed sha256sum wc "$USIGN_BIN"; do need "$tool"; done

[ -d "$RELEASE_DIR" ] || fail "missing release directory: $RELEASE_DIR"
printf '%s' "$FACTORY_PRODUCT_VERSION" |
  grep -Eq '^0\.7\.11-rc\.[1-9][0-9]*$' ||
  fail "FACTORY_PRODUCT_VERSION must be an exact 0.7.11 RC semantic version"
printf '%s' "$FACTORY_RELEASE_PUBLISHED_AT" |
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ||
  fail "FACTORY_RELEASE_PUBLISHED_AT must be an RFC3339 UTC timestamp"
case "$FACTORY_REQUIRED_PERSISTENT_BYTES:$FACTORY_REQUIRED_TMP_BYTES" in
  *[!0-9:]*|:*|*:) fail "Factory storage requirements must be positive byte counts" ;;
esac
[ "$FACTORY_REQUIRED_PERSISTENT_BYTES" -gt 0 ] &&
  [ $((FACTORY_REQUIRED_PERSISTENT_BYTES % 1024)) -eq 0 ] ||
  fail "Factory persistent requirement must be an exact KiB multiple"
[ "$FACTORY_REQUIRED_TMP_BYTES" -gt 0 ] &&
  [ $((FACTORY_REQUIRED_TMP_BYTES % 1024)) -eq 0 ] ||
  fail "Factory temporary requirement must be an exact KiB multiple"

pr_require_active_signing_key || exit 1

UPDATER_MANIFEST="$RELEASE_DIR/router-release-manifest.json"
[ -s "$UPDATER_MANIFEST" ] || fail "missing updater release manifest"
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$UPDATER_MANIFEST" \
  -x "$RELEASE_DIR/router-release-manifest.json.sig" ||
  fail "updater release manifest signature is invalid"

SOURCE_COMMIT="$(jq -er '.source_commit | select(test("^[0-9a-f]{40}$"))' "$UPDATER_MANIFEST")"
PACKAGE_RELEASE="$(jq -er '.package_version | select(type == "string")' "$UPDATER_MANIFEST")"
[ "$(jq -er .app_version "$UPDATER_MANIFEST")" = 0.7.11 ] ||
  fail "Factory projection is scoped to Router UI 0.7.11"
[ "$(jq -er .channel "$UPDATER_MANIFEST")" = candidate ] ||
  fail "Factory RC projection requires a candidate updater manifest"
[ "$(jq -er .source_dirty "$UPDATER_MANIFEST")" = false ] ||
  fail "Factory RC projection refuses dirty source"
[ "$(jq -er .signing_key_id "$UPDATER_MANIFEST")" = "$RELEASE_KEY_ID" ] ||
  fail "updater manifest signing key ID mismatch"
[ "$(jq -er .signing_key_fingerprint "$UPDATER_MANIFEST")" = "$RELEASE_KEY_FINGERPRINT" ] ||
  fail "updater manifest signing fingerprint mismatch"

PACKAGES_JSON="$(jq -c '
  [.packages[] | {name,filename,version,sha256}] |
  select(length == 3) |
  select([.[].name] ==
    ["premier-router-core","luci-app-premier-router","premier-router-setup"])
' "$UPDATER_MANIFEST")"
[ -n "$PACKAGES_JSON" ] || fail "updater manifest canonical package set is invalid"
printf '%s\n' "$PACKAGES_JSON" |
  jq -e --arg release "$PACKAGE_RELEASE" 'all(.[]; .version == $release)' >/dev/null ||
  fail "updater manifest package versions do not agree"
printf '%s\n' "$PACKAGES_JSON" |
  jq -c '.[]' |
  while IFS= read -r package; do
    filename="$(printf '%s\n' "$package" | jq -er .filename)"
    expected="$(printf '%s\n' "$package" | jq -er .sha256)"
    [ -s "$RELEASE_DIR/$filename" ] || fail "missing Factory package asset: $filename"
    [ "$(sha256sum "$RELEASE_DIR/$filename" | awk '{print $1}')" = "$expected" ] ||
      fail "Factory package asset hash mismatch: $filename"
  done

IMAGE_JSON="$(jq -c '
  [.images[] | select(.target == "x86/64" and .profile == "generic")] |
  select(length == 1) | .[0]
' "$UPDATER_MANIFEST")"
[ -n "$IMAGE_JSON" ] || fail "candidate must contain exactly one generic x86/64 image"
IMAGE_FILENAME="$(printf '%s\n' "$IMAGE_JSON" | jq -er .filename)"
IMAGE_SHA256="$(printf '%s\n' "$IMAGE_JSON" | jq -er .sha256)"
[ -s "$RELEASE_DIR/$IMAGE_FILENAME" ] || fail "missing Factory x86 image asset"
[ "$(sha256sum "$RELEASE_DIR/$IMAGE_FILENAME" | awk '{print $1}')" = "$IMAGE_SHA256" ] ||
  fail "Factory x86 image hash mismatch"

IMAGE_PACKAGE_MANIFEST="$RELEASE_DIR/image-package-manifest.json"
jq -n --argjson packages "$PACKAGES_JSON" \
  '{schema_version:1,project_packages:
    [$packages[] | {name,version,sha256}]}' |
  jq -S . > "$IMAGE_PACKAGE_MANIFEST"
IMAGE_PACKAGE_MANIFEST_DIGEST="$(sha256sum "$IMAGE_PACKAGE_MANIFEST" | awk '{print $1}')"

FACTORY_MANIFEST="$RELEASE_DIR/factory-router-release-manifest.json"
jq -n \
  --arg app_version "$FACTORY_PRODUCT_VERSION" \
  --arg package_version "$PACKAGE_RELEASE" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg published_at "$FACTORY_RELEASE_PUBLISHED_AT" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" \
  --arg image_filename "$IMAGE_FILENAME" \
  --arg image_sha256 "$IMAGE_SHA256" \
  --arg package_manifest_digest "$IMAGE_PACKAGE_MANIFEST_DIGEST" \
  --argjson packages "$PACKAGES_JSON" \
  --argjson persistent_kib $((FACTORY_REQUIRED_PERSISTENT_BYTES / 1024)) \
  --argjson temporary_kib $((FACTORY_REQUIRED_TMP_BYTES / 1024)) \
  '{
    schema_version:2,
    update_protocol:2,
    channel:"candidate",
    app_version:$app_version,
    package_version:$package_version,
    source_commit:$source_commit,
    signing_key_id:$signing_key_id,
    signing_key_fingerprint:$signing_key_fingerprint,
    prerelease:true,
    published_at:$published_at,
    storage_requirements:{
      persistent_min_free_kib:$persistent_kib,
      temporary_min_free_kib:$temporary_kib
    },
    packages:$packages,
    images:[{
      filename:$image_filename,
      target:"x86/64",
      profile:"generic",
      variant:"virtualbox",
      sha256:$image_sha256,
      package_manifest_digest:$package_manifest_digest
    }]
  }' | jq -S . > "$FACTORY_MANIFEST"
"$USIGN_BIN" -S -m "$FACTORY_MANIFEST" -s "$SIGNING_KEY" \
  -x "$FACTORY_MANIFEST.sig"

FACTORY_CONTRACT="$RELEASE_DIR/factory-release-contract.json"
jq -n \
  --arg product_version "$FACTORY_PRODUCT_VERSION" \
  --arg package_release "$PACKAGE_RELEASE" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg signing_key_id "$RELEASE_KEY_ID" \
  --arg signing_key_fingerprint "$RELEASE_KEY_FINGERPRINT" \
  --arg release_published_at "$FACTORY_RELEASE_PUBLISHED_AT" \
  --arg minimum_factory_version "$FACTORY_MINIMUM_VERSION" \
  --arg release_manifest_filename "$(basename "$FACTORY_MANIFEST")" \
  --arg release_manifest_signature_filename "$(basename "$FACTORY_MANIFEST.sig")" \
  --arg release_manifest_sha256 "$(sha256sum "$FACTORY_MANIFEST" | awk '{print $1}')" \
  --arg image_filename "$IMAGE_FILENAME" \
  --arg image_sha256 "$IMAGE_SHA256" \
  --arg image_package_manifest_filename "$(basename "$IMAGE_PACKAGE_MANIFEST")" \
  --arg image_package_manifest_digest "$IMAGE_PACKAGE_MANIFEST_DIGEST" \
  --argjson packages "$PACKAGES_JSON" \
  --argjson required_persistent_free_bytes "$FACTORY_REQUIRED_PERSISTENT_BYTES" \
  --argjson required_tmp_free_bytes "$FACTORY_REQUIRED_TMP_BYTES" \
  '{
    schema_version:2,
    semantic_version:$product_version,
    product_version:$product_version,
    package_release:$package_release,
    updater_protocol:2,
    source_commit:$source_commit,
    manifest_schema:2,
    release_manifest_filename:$release_manifest_filename,
    release_manifest_signature_filename:$release_manifest_signature_filename,
    release_manifest_sha256:$release_manifest_sha256,
    signing_key_id:$signing_key_id,
    signing_key_fingerprint:$signing_key_fingerprint,
    release_channel:"rc",
    prerelease:true,
    release_published_at:$release_published_at,
    minimum_factory_version:$minimum_factory_version,
    installation_mode:"factory-image",
    setup_schema_version:1,
    factory_metadata_schema_version:1,
    supported_upgrade_sources:["0.7.9","0.7.10"],
    required_persistent_free_bytes:$required_persistent_free_bytes,
    required_tmp_free_bytes:$required_tmp_free_bytes,
    openwrt_feed_lock_id:"openwrt-24.10.5-locked-v1",
    artifacts:[{
      hardware_target:"x86/64",
      image_profile:"generic",
      variant:"virtualbox",
      image_filename:$image_filename,
      image_sha256:$image_sha256,
      image_package_manifest_filename:$image_package_manifest_filename,
      image_package_manifest_digest:$image_package_manifest_digest,
      packages:$packages
    }]
  }' | jq -S . > "$FACTORY_CONTRACT"
"$USIGN_BIN" -S -m "$FACTORY_CONTRACT" -s "$SIGNING_KEY" \
  -x "$FACTORY_CONTRACT.sig"

printf 'Staged signed Factory schema-2 contract for %s at %s\n' \
  "$FACTORY_PRODUCT_VERSION" "$RELEASE_DIR"
