#!/bin/bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT_DIR/tests/vm/router-ui-vm-gate.sh"
LOCK="$ROOT_DIR/tests/vm/legacy-baseline-lock.json"
IMMUTABLE_RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR is required}"
BASELINE_PACK_DIR="${ROUTER_UI_BASELINE_PACK_DIR:?ROUTER_UI_BASELINE_PACK_DIR is required}"
EVIDENCE_DIR="${EVIDENCE_DIR:?EVIDENCE_DIR is required}"
RUNNER_TEMP="${RUNNER_TEMP:?RUNNER_TEMP is required}"

fail() { printf 'PREIMAGE-RESCUE-ERROR: %s\n' "$*" >&2; exit 1; }
[[ "${ROUTER_UI_VM_DIAGNOSTIC:-0}" = 1 ]] || fail "pre-image smoke must be diagnostic"
[[ "${ROUTER_UI_VM_MODE:-candidate}" = candidate ]] || fail "pre-image smoke is candidate-mode only"
[[ "${ROUTER_UI_VM_CASE:-}" = rescue ]] || fail "pre-image smoke accepts only rescue"
[[ "${ROUTER_UI_VM_SOURCE_VERSION:-}" = 0.7.0 ]] || fail "pre-image smoke accepts only source 0.7.0"
[[ "${ROUTER_UI_VM_PHASE:-all}" = all ]] || fail "pre-image smoke accepts only the complete rescue phase"
[[ -z "${ROUTER_UI_VM_FAULT_BOUNDARY:-}" ]] || fail "pre-image smoke rejects fault injection"
[[ -d "$IMMUTABLE_RELEASE_DIR" && -d "$BASELINE_PACK_DIR" ]] || fail "immutable inputs are missing"
[[ -z "$(find "$IMMUTABLE_RELEASE_DIR" -maxdepth 1 -type f \
  \( -name '*x86-64.tar.gz' -o -name '*xiaomi-ax3000t-stock.tar.gz' \
  -o -name '*xiaomi-ax3000t-ubootmod.tar.gz' \) -print)" ]] ||
  fail "pre-image smoke refuses a final image release"

release_manifest="$IMMUTABLE_RELEASE_DIR/router-release-manifest.json"
[[ -s "$release_manifest" ]] || fail "immutable transition candidate manifest is missing"
candidate_app_version="$(jq -er '.app_version' "$release_manifest")"
candidate_package_version="$(jq -er '.package_version' "$release_manifest")"
jq -e '
  .app_version == "0.7.11-rc.7" and .package_version == "0.7.11~rc7-1" and
  .release_tag == "vpn-panel-v0.7.11-rc.7" and .channel == "candidate" and
  .source_dirty == false
' "$release_manifest" >/dev/null || fail "immutable transition candidate is not the exact RC7 contract"

manifest="$BASELINE_PACK_DIR/baseline-pack-manifest.json"
descriptor="$BASELINE_PACK_DIR/baseline-pack-descriptor.json"
[[ -s "$manifest" && -s "$descriptor" ]] || fail "verified baseline descriptor is missing"
manifest_sha="$(sha256sum "$manifest" | awk '{print $1}')"
contract_digest="$(sh "$ROOT_DIR/tests/vm/baseline-contract-digest.sh")"
jq -e --arg manifest "$manifest_sha" --arg contract "$contract_digest" '
  .schema_version == 1 and .immutable == true and
  .manifest_sha256 == $manifest and .baseline_contract_digest == $contract
' "$descriptor" >/dev/null || fail "baseline descriptor does not bind the current verified contract"
jq -e --slurpfile lock "$LOCK" '
  .verified == true and .storage_profiles == $lock[0].storage_profiles
' "$manifest" >/dev/null || fail "baseline manifest storage geometry differs from its verified lock"

work="$(mktemp -d "$RUNNER_TEMP/router-ui-preimage-rescue.XXXXXX")"
case "$work" in "$RUNNER_TEMP"/*) ;; *) fail "temporary work escaped RUNNER_TEMP" ;; esac
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM
geometry_root="$work/diagnostic-geometry"
gate_input="$work/gate-input"
mkdir -p "$geometry_root" "$gate_input" "$EVIDENCE_DIR"
cp -Rp "$IMMUTABLE_RELEASE_DIR/." "$gate_input/"

for profile in rd23-stock rd23-ubootmod; do
  case "$profile" in
    rd23-stock) suffix=xiaomi-ax3000t-stock ;;
    rd23-ubootmod) suffix=xiaomi-ax3000t-ubootmod ;;
  esac
  backing="$(jq -er --arg profile "$profile" \
    '.storage_profiles[$profile].writable_backing_kib' "$manifest")"
  ubifs_df="$(jq -er --arg profile "$profile" \
    '.storage_profiles[$profile].expected_ubifs_df_total_kib' "$manifest")"
  archive_root="$geometry_root/router-ui-$profile"
  mkdir -p "$archive_root"
  jq -n --arg profile "$profile" --argjson backing "$backing" \
    --argjson ubifs_df "$ubifs_df" --arg manifest_sha256 "$manifest_sha" \
    --arg baseline_contract_digest "$contract_digest" '
    {schema_version:1,diagnostic_geometry_only:true,storage_profile:$profile,
     writable_backing_kib:$backing,expected_ubifs_df_total_kib:$ubifs_df,
     rd23_storage_layout:{rootfs_data_volume_kib:$backing},
     source:"verified-baseline-pack-descriptor",baseline_manifest_sha256:$manifest_sha256,
     baseline_contract_digest:$baseline_contract_digest}
  ' > "$archive_root/image-provenance.json"
  archive="$geometry_root/preimage-rescue-$suffix.tar.gz"
  tar -czf "$archive" -C "$geometry_root" "$(basename "$archive_root")"
  ln "$archive" "$gate_input/premier-router-$candidate_app_version-openwrt-24.10.5-$suffix.tar.gz"
  cp "$archive_root/image-provenance.json" "$EVIDENCE_DIR/$profile-diagnostic-geometry.json"
done

before="$(cd "$IMMUTABLE_RELEASE_DIR" && find . -type f -print0 | LC_ALL=C sort -z |
  xargs -0 sha256sum | sha256sum | awk '{print $1}')"
core_ipk="$(find "$IMMUTABLE_RELEASE_DIR" -maxdepth 1 -type f \
  -name "premier-router-core_${candidate_package_version}_all.ipk" | sed -n '1p')"
[[ -n "$core_ipk" ]] || fail "immutable transition candidate lacks the core IPK"
RELEASE_DIR="$gate_input" X86_IMAGE_ARCHIVE="$core_ipk" "$GATE"
after="$(cd "$IMMUTABLE_RELEASE_DIR" && find . -type f -print0 | LC_ALL=C sort -z |
  xargs -0 sha256sum | sha256sum | awk '{print $1}')"
[[ "$before" = "$after" ]] || fail "pre-image smoke mutated immutable candidate bytes"
