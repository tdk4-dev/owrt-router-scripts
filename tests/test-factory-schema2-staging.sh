#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
USIGN_BIN="${TEST_USIGN_BIN:-${USIGN_BIN:-$(command -v usign || true)}}"
[ -x "$USIGN_BIN" ] || { printf 'usign is required for Factory schema-2 staging tests\n' >&2; exit 1; }
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/factory-schema2-stage-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

SECRET="$TMP_ROOT/test.sec"
PUBLIC="$TMP_ROOT/test.pub"
"$USIGN_BIN" -G -s "$SECRET" -p "$PUBLIC" -c 'Factory schema-2 staging ephemeral test key'
KEY_ID="test-$("$USIGN_BIN" -F -p "$PUBLIC")"
FINGERPRINT="$("$USIGN_BIN" -F -p "$PUBLIC")"
TRUST_ROOT="$TMP_ROOT/trust-root"
mkdir -p "$TRUST_ROOT/keys/release" "$TMP_ROOT/release"
cp "$PUBLIC" "$TRUST_ROOT/keys/release/test.pub"
jq -n --arg key_id "$KEY_ID" --arg fingerprint "$FINGERPRINT" \
  '{schema_version:1,active_key_id:$key_id,keys:[{
    key_id:$key_id,fingerprint:$fingerprint,status:"active",
    creation_date:"2026-07-24",public_key_path:"keys/release/test.pub"}]}' \
  > "$TRUST_ROOT/keys/release/trusted-keys.json"

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
for package in premier-router-core luci-app-premier-router premier-router-setup; do
  printf '%s\n' "$package" > "$TMP_ROOT/release/${package}_0.7.11-1_all.ipk"
done
IMAGE="premier-router-0.7.11-openwrt-24.10.5-x86-64.tar.gz"
printf 'x86 validation image\n' > "$TMP_ROOT/release/$IMAGE"
packages="$(
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    file="$TMP_ROOT/release/${package}_0.7.11-1_all.ipk"
    jq -n --arg name "$package" --arg filename "$(basename "$file")" \
      --arg version 0.7.11-1 \
      --arg sha256 "$(sha256sum "$file" | awk '{print $1}')" \
      '{name:$name,filename:$filename,version:$version,sha256:$sha256}'
  done | jq -s .
)"
jq -n --arg source_commit "$SOURCE_COMMIT" --arg key "$KEY_ID" \
  --arg fingerprint "$FINGERPRINT" --arg image "$IMAGE" \
  --arg image_sha "$(sha256sum "$TMP_ROOT/release/$IMAGE" | awk '{print $1}')" \
  --argjson packages "$packages" '
  {
    schema_version:2,update_protocol:2,channel:"candidate",
    app_version:"0.7.11",package_version:"0.7.11-1",
    source_commit:$source_commit,source_dirty:false,
    signing_key_id:$key,signing_key_fingerprint:$fingerprint,
    packages:$packages,
    images:[{filename:$image,target:"x86/64",profile:"generic",sha256:$image_sha}]
  }' | jq -S . > "$TMP_ROOT/release/router-release-manifest.json"
"$USIGN_BIN" -S -m "$TMP_ROOT/release/router-release-manifest.json" -s "$SECRET" \
  -x "$TMP_ROOT/release/router-release-manifest.json.sig"

ROUTER_UI_TRUSTED_KEYS_FILE="$TRUST_ROOT/keys/release/trusted-keys.json" \
ROUTER_UI_TRUST_ROOT="$TRUST_ROOT" \
ROUTER_UI_SIGNING_KEY_ID="$KEY_ID" \
ROUTER_UI_SIGNING_KEY="$SECRET" \
RELEASE_DIR="$TMP_ROOT/release" \
FACTORY_PRODUCT_VERSION=0.7.11-rc.4 \
FACTORY_RELEASE_PUBLISHED_AT=2026-07-24T12:00:00Z \
USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/stage-factory-schema2-contract.sh" >/dev/null

for signed in factory-release-contract.json factory-router-release-manifest.json; do
  "$USIGN_BIN" -q -V -p "$PUBLIC" -m "$TMP_ROOT/release/$signed" \
    -x "$TMP_ROOT/release/$signed.sig"
done
jq -e --arg commit "$SOURCE_COMMIT" '
  .schema_version == 2 and .semantic_version == "0.7.11-rc.4" and
  .product_version == "0.7.11-rc.4" and .package_release == "0.7.11-1" and
  .source_commit == $commit and .release_channel == "rc" and
  .prerelease == true and (.artifacts | length == 1) and
  .artifacts[0].hardware_target == "x86/64" and
  .artifacts[0].variant == "virtualbox"
' "$TMP_ROOT/release/factory-release-contract.json" >/dev/null
jq -e '
  .schema_version == 2 and .app_version == "0.7.11-rc.4" and
  .package_version == "0.7.11-1" and .channel == "candidate" and
  .prerelease == true and (.images | length == 1)
' "$TMP_ROOT/release/factory-router-release-manifest.json" >/dev/null

if ROUTER_UI_TRUSTED_KEYS_FILE="$TRUST_ROOT/keys/release/trusted-keys.json" \
  ROUTER_UI_TRUST_ROOT="$TRUST_ROOT" ROUTER_UI_SIGNING_KEY_ID="$KEY_ID" \
  ROUTER_UI_SIGNING_KEY="$SECRET" RELEASE_DIR="$TMP_ROOT/release" \
  FACTORY_PRODUCT_VERSION=0.7.11 FACTORY_RELEASE_PUBLISHED_AT=2026-07-24T12:00:00Z \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/stage-factory-schema2-contract.sh" \
  >"$TMP_ROOT/stable-reject.log" 2>&1; then
  printf 'Factory schema-2 stager accepted a non-RC identity\n' >&2
  exit 1
fi
grep -q 'must be an exact 0.7.11 RC semantic version' "$TMP_ROOT/stable-reject.log"

printf 'Factory schema-2 RC staging tests passed\n'
