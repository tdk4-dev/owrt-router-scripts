#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
RELEASE_DIR="${1:?release directory is required}"
SYNTHETIC_DIR="${2:?synthetic directory is required}"
OUTPUT="${3:?descriptor output is required}"
USIGN_BIN="${USIGN_BIN:?USIGN_BIN is required}"

case "$USIGN_BIN" in /*) ;; *) printf 'USIGN_BIN must be absolute\n' >&2; exit 1 ;; esac
[ -x "$USIGN_BIN" ] || { printf 'USIGN_BIN is not executable\n' >&2; exit 1; }

key_id="$(jq -er .active_key_id "$ROOT_DIR/release/keys/trusted-keys.json")"
key_fingerprint="$(jq -er --arg key "$key_id" \
  '.keys[] | select(.key_id == $key and .status == "active") | .fingerprint' \
  "$ROOT_DIR/release/keys/trusted-keys.json")"
public_key_relative="$(jq -er --arg key "$key_id" \
  '.keys[] | select(.key_id == $key and .status == "active") | .public_key_path' \
  "$ROOT_DIR/release/keys/trusted-keys.json")"
public_key="$ROOT_DIR/$public_key_relative"
[ -s "$public_key" ] || { printf 'active public key is missing\n' >&2; exit 1; }
[ "$("$USIGN_BIN" -F -p "$public_key")" = "$key_fingerprint" ] || {
  printf 'active public key fingerprint mismatch\n' >&2
  exit 1
}

verify_inventory() {
  inventory_directory="$1"
  inventory_actual="$(mktemp "${TMPDIR:-/tmp}/router-ui-content.actual.XXXXXX")"
  inventory_expected="$(mktemp "${TMPDIR:-/tmp}/router-ui-content.expected.XXXXXX")"
  (cd "$inventory_directory" && find . -maxdepth 1 -type f \
    ! -name SHA256SUMS ! -name SHA256SUMS.sig -print | LC_ALL=C sort) > "$inventory_actual"
  (cd "$inventory_directory" && awk '{name=$2; sub(/^\*/, "", name); print "./" name}' \
    SHA256SUMS | LC_ALL=C sort) > "$inventory_expected"
  if ! cmp -s "$inventory_actual" "$inventory_expected"; then
    rm -f "$inventory_actual" "$inventory_expected"
    printf 'unmanifested or missing release file: %s\n' "$inventory_directory" >&2
    exit 1
  fi
  rm -f "$inventory_actual" "$inventory_expected"
}

for directory in "$RELEASE_DIR" "$SYNTHETIC_DIR"; do
  [ -s "$directory/router-release-manifest.json" ] || exit 1
  [ -s "$directory/SHA256SUMS" ] || exit 1
  [ -s "$directory/SHA256SUMS.sig" ] || exit 1
  (cd "$directory" && sha256sum -c SHA256SUMS >/dev/null)
  verify_inventory "$directory"
  "$USIGN_BIN" -q -V -p "$public_key" -m "$directory/SHA256SUMS" \
    -x "$directory/SHA256SUMS.sig"
  if [ "$directory" = "$RELEASE_DIR" ]; then
    channel_file=candidate-channel.json
  else
    channel_file=stable-channel.json
  fi
  for signed in router-release-manifest.json "$channel_file" release-provenance.json; do
    [ -s "$directory/$signed" ] && [ -s "$directory/$signed.sig" ] || exit 1
    "$USIGN_BIN" -q -V -p "$public_key" -m "$directory/$signed" \
      -x "$directory/$signed.sig"
  done
done

source_sha="$(jq -er .source_commit "$RELEASE_DIR/router-release-manifest.json")"
[ "$source_sha" = "$(jq -er .source_commit "$SYNTHETIC_DIR/router-release-manifest.json")" ]
jq -e --arg source "$source_sha" --arg key "$key_id" --arg fingerprint "$key_fingerprint" \
  '.source_commit == $source and .source_dirty == false and
   .app_version == "0.7.11-rc.8" and .package_version == "0.7.11~rc8-1" and
   .release_tag == "vpn-panel-v0.7.11-rc.8" and .channel == "candidate" and
   .signing_key_id == $key and .signing_key_fingerprint == $fingerprint' \
  "$RELEASE_DIR/router-release-manifest.json" >/dev/null
jq -e --arg source "$source_sha" --arg key "$key_id" --arg fingerprint "$key_fingerprint" \
  '.source_commit == $source and .source_dirty == false and
   .app_version == "0.7.11" and .package_version == "0.7.11-1" and
   .release_tag == "vpn-panel-v0.7.11" and .channel == "stable" and
   .signing_key_id == $key and .signing_key_fingerprint == $fingerprint' \
  "$SYNTHETIC_DIR/router-release-manifest.json" >/dev/null

candidate_app_version="$(jq -er .app_version "$RELEASE_DIR/router-release-manifest.json")"
candidate_package_version="$(jq -er .package_version "$RELEASE_DIR/router-release-manifest.json")"
candidate_release_tag="$(jq -er .release_tag "$RELEASE_DIR/router-release-manifest.json")"
successor_app_version="$(jq -er .app_version "$SYNTHETIC_DIR/router-release-manifest.json")"
successor_package_version="$(jq -er .package_version "$SYNTHETIC_DIR/router-release-manifest.json")"
successor_release_tag="$(jq -er .release_tag "$SYNTHETIC_DIR/router-release-manifest.json")"

jq -n --arg product_source_sha "$source_sha" --arg production_key_id "$key_id" \
  --arg production_key_fingerprint "$key_fingerprint" \
  --arg candidate_app_version "$candidate_app_version" \
  --arg candidate_package_version "$candidate_package_version" \
  --arg candidate_release_tag "$candidate_release_tag" \
  --arg successor_app_version "$successor_app_version" \
  --arg successor_package_version "$successor_package_version" \
  --arg successor_release_tag "$successor_release_tag" \
  --arg release_manifest_sha256 "$(sha256sum "$RELEASE_DIR/router-release-manifest.json" | awk '{print $1}')" \
  --arg release_sha256sums_sha256 "$(sha256sum "$RELEASE_DIR/SHA256SUMS" | awk '{print $1}')" \
  --arg synthetic_manifest_sha256 "$(sha256sum "$SYNTHETIC_DIR/router-release-manifest.json" | awk '{print $1}')" \
  --arg synthetic_sha256sums_sha256 "$(sha256sum "$SYNTHETIC_DIR/SHA256SUMS" | awk '{print $1}')" '
    {schema_version:1,kind:"router-ui-candidate-content",immutable:true,
     product_source_sha:$product_source_sha,production_key_id:$production_key_id,
     production_key_fingerprint:$production_key_fingerprint,
     candidate:{app_version:$candidate_app_version,package_version:$candidate_package_version,
       release_tag:$candidate_release_tag},
     successor:{app_version:$successor_app_version,package_version:$successor_package_version,
       release_tag:$successor_release_tag},
     release_manifest_sha256:$release_manifest_sha256,
     release_sha256sums_sha256:$release_sha256sums_sha256,
     synthetic_manifest_sha256:$synthetic_manifest_sha256,
     synthetic_sha256sums_sha256:$synthetic_sha256sums_sha256,
     manifested_bytes_verified:true,signatures_verified:true}
  ' > "$OUTPUT"
