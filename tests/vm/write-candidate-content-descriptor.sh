#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
RELEASE_DIR="${1:?release directory is required}"
SYNTHETIC_DIR="${2:?synthetic directory is required}"
OUTPUT="${3:?descriptor output is required}"

for directory in "$RELEASE_DIR" "$SYNTHETIC_DIR"; do
  [ -s "$directory/router-release-manifest.json" ] || exit 1
  [ -s "$directory/SHA256SUMS" ] || exit 1
  (cd "$directory" && sha256sum -c SHA256SUMS >/dev/null)
done

source_sha="$(jq -er .source_commit "$RELEASE_DIR/router-release-manifest.json")"
[ "$source_sha" = "$(jq -er .source_commit "$SYNTHETIC_DIR/router-release-manifest.json")" ]
key_id="$(jq -er .active_key_id "$ROOT_DIR/release/keys/trusted-keys.json")"
key_fingerprint="$(jq -er --arg key "$key_id" \
  '.keys[] | select(.key_id == $key) | .fingerprint' "$ROOT_DIR/release/keys/trusted-keys.json")"
jq -e --arg source "$source_sha" --arg key "$key_id" --arg fingerprint "$key_fingerprint" \
  '.source_commit == $source and .source_dirty == false and .app_version == "0.7.11" and
   .signing_key_id == $key and .signing_key_fingerprint == $fingerprint' \
  "$RELEASE_DIR/router-release-manifest.json" >/dev/null
jq -e --arg source "$source_sha" --arg key "$key_id" --arg fingerprint "$key_fingerprint" \
  '.source_commit == $source and .source_dirty == false and .app_version == "0.7.12" and
   .signing_key_id == $key and .signing_key_fingerprint == $fingerprint' \
  "$SYNTHETIC_DIR/router-release-manifest.json" >/dev/null

jq -n --arg product_source_sha "$source_sha" --arg production_key_id "$key_id" \
  --arg production_key_fingerprint "$key_fingerprint" \
  --arg release_manifest_sha256 "$(sha256sum "$RELEASE_DIR/router-release-manifest.json" | awk '{print $1}')" \
  --arg release_sha256sums_sha256 "$(sha256sum "$RELEASE_DIR/SHA256SUMS" | awk '{print $1}')" \
  --arg synthetic_manifest_sha256 "$(sha256sum "$SYNTHETIC_DIR/router-release-manifest.json" | awk '{print $1}')" \
  --arg synthetic_sha256sums_sha256 "$(sha256sum "$SYNTHETIC_DIR/SHA256SUMS" | awk '{print $1}')" '
    {schema_version:1,kind:"router-ui-candidate-content",immutable:true,
     product_source_sha:$product_source_sha,production_key_id:$production_key_id,
     production_key_fingerprint:$production_key_fingerprint,
     release_manifest_sha256:$release_manifest_sha256,
     release_sha256sums_sha256:$release_sha256sums_sha256,
     synthetic_manifest_sha256:$synthetic_manifest_sha256,
     synthetic_sha256sums_sha256:$synthetic_sha256sums_sha256,
     manifested_bytes_verified:true}
  ' > "$OUTPUT"
