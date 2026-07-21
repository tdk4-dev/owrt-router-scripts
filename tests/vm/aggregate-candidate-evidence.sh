#!/bin/bash
set -Eeuo pipefail
umask 077

EVIDENCE_ROOT="${EVIDENCE_ROOT:?EVIDENCE_ROOT is required}"
RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR is required}"
OUT_DIR="${OUT_DIR:?OUT_DIR is required}"
EXPECTED_BASELINE_DIGEST="${EXPECTED_BASELINE_DIGEST:?EXPECTED_BASELINE_DIGEST is required}"

fail() { printf 'CANDIDATE-EVIDENCE-ERROR: %s\n' "$*" >&2; exit 1; }
for tool in find jq sha256sum sort; do command -v "$tool" >/dev/null 2>&1 || fail "missing $tool"; done
[[ -d "$EVIDENCE_ROOT" && -s "$RELEASE_DIR/router-release-manifest.json" ]] ||
  fail "evidence root or release manifest is missing"
[[ "$EXPECTED_BASELINE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "baseline artifact digest is malformed"
mkdir -p "$OUT_DIR"

source_sha="$(jq -er '.source_commit' "$RELEASE_DIR/router-release-manifest.json")"
key_fingerprint="5b001ed1f9e63c96"

find "$EVIDENCE_ROOT" -type f -name shard-identity.json -print0 | LC_ALL=C sort -z |
  xargs -0 jq -c . > "$OUT_DIR/shard-identities.jsonl"
jq -s -e --arg source "$source_sha" '
  length == 4 and ([.[].shard] | unique | length) == 4 and
  all(.[ ]; .candidate_source_sha == $source and .complete == true)
  ' "$OUT_DIR/shard-identities.jsonl" >/dev/null || fail "shard identity or completion contract failed"

while IFS= read -r sums; do
  (cd "$(dirname "$sums")" && sha256sum -c "$(basename "$sums")" >/dev/null)
done < <(find "$EVIDENCE_ROOT" -type f -name SHA256SUMS | LC_ALL=C sort)
while IFS= read -r sums; do
  (cd "$(dirname "$sums")" && sha256sum -c "$(basename "$sums")" >/dev/null)
done < <(find "$EVIDENCE_ROOT" -type f -name shard-files-sha256sums | LC_ALL=C sort)

find "$EVIDENCE_ROOT" -type f -name summary.json -print0 | LC_ALL=C sort -z |
  xargs -0 jq -c . > "$OUT_DIR/shard-summaries.jsonl"
[[ "$(wc -l < "$OUT_DIR/shard-summaries.jsonl" | tr -d ' ')" -eq 22 ]] ||
  fail "expected exactly 22 independently finalized VM case summaries"
jq -s -e --arg source "$source_sha" --arg fingerprint "$key_fingerprint" \
  --arg baseline "$EXPECTED_BASELINE_DIGEST" '
    length == 22 and all(.[ ];
      .candidate_source_sha == $source and
      .production_public_key_fingerprint == $fingerprint and
      .harness_source_sha == $source and
      .baseline_pack_digest == $baseline and
      .diagnostic == true and .release_evidence == false and
      .configured_ram_mib == 256 and
      .vm_execution_mode == "strictly-serial-exact-child-pid" and
      .storage_profiles["rd23-stock"].writable_backing_kib == 54436 and
      .storage_profiles["rd23-stock"].expected_ubifs_df_total_kib == 51352 and
      .storage_profiles["rd23-ubootmod"].writable_backing_kib == 80352 and
      .storage_profiles["rd23-ubootmod"].expected_ubifs_df_total_kib == 76728)
  ' "$OUT_DIR/shard-summaries.jsonl" >/dev/null || fail "shard summary contract failed"

for stem in vm-measurements transition-results fault-results storage-results; do
  find "$EVIDENCE_ROOT" -type f -name "$stem.jsonl" -print0 | LC_ALL=C sort -z |
    xargs -0 cat > "$OUT_DIR/$stem.jsonl"
done

jq -s -e '
  length > 0 and all(.[ ];
    .configured_ram_mib == 256 and .mem_total_kib >= 220000 and .mem_total_kib <= 262144 and
    .tmp_ram_backed == true and .overlay_total_kib <= .overlay_backing_kib and
    ((.profile == "rd23-stock" and .overlay_backing_kib == 54436 and
      .target_expected_ubifs_df_total_kib == 51352) or
     (.profile == "rd23-ubootmod" and .overlay_backing_kib == 80352 and
      .target_expected_ubifs_df_total_kib == 76728)))
  ' "$OUT_DIR/vm-measurements.jsonl" >/dev/null || fail "VM RAM or storage measurement contract failed"
jq -s -e 'all(.[ ]; .status == "pass")' \
  "$OUT_DIR/transition-results.jsonl" "$OUT_DIR/fault-results.jsonl" \
  "$OUT_DIR/storage-results.jsonl" >/dev/null || fail "one or more VM results did not pass"

require_transition() {
  local kind="$1" name="$2"
  jq -s -e --arg kind "$kind" --arg name "$name" \
    '[.[] | select(.kind == $kind and .name == $name and .status == "pass")] | length == 1' \
    "$OUT_DIR/transition-results.jsonl" >/dev/null || fail "missing transition: $kind $name"
}
for version in 0.7.9 0.7.10; do
  require_transition old-worker "$version->0.7.11->rollback"
done
while IFS= read -r version; do
  require_transition rescue "$version->0.7.11->rollback"
done < <(jq -r '.transitions[] | select((.mode | contains("rescue")) and .source_version != "0.7.11") | .source_version' \
  "$RELEASE_DIR/router-release-manifest.json")
for refusal in 0.7.7 unknown 0.7 development 0.7.11RC1 0.8.0 direct-other-target; do
  require_transition refusal "$refusal"
done
require_transition image clean-x86-boot
require_transition protocol-v2 '0.7.11->0.7.12->0.7.11->0.7.12->0.7.11'
require_transition concurrency cli-rpc-cron

jq -s -e '
  [.[] | select(.kind == "old-worker") | .details] | length == 2 and
  all(.[ ]; has("transaction") and has("disk_before") and has("disk_candidate") and
    has("disk_committed") and has("disk_rolled_back") and has("disk_after_reboot"))
  ' "$OUT_DIR/transition-results.jsonl" >/dev/null || fail "old-worker reboot or rollback evidence is incomplete"
jq -s -e '
  [.[] | select(.kind == "rescue") | .details] as $rows |
  ($rows | length) >= 10 and all($rows[];
    has("transaction") and has("disk_before") and has("disk_candidate") and
    has("disk_committed") and has("disk_rolled_back") and has("disk_after_rollback_reboot"))
  ' "$OUT_DIR/transition-results.jsonl" >/dev/null || fail "rescue reboot or rollback evidence is incomplete"
jq -s -e '
  any(.[]; .kind == "protocol-v2" and .details.protected_state_matches == true and
    .details.retained_directories <= 6)
  ' "$OUT_DIR/transition-results.jsonl" >/dev/null || fail "protocol-v2 retention evidence is incomplete"

for pressure in normal-success slightly-above-reservation below-reservation-refusal; do
  jq -s -e --arg name "$pressure" \
    '[.[] | select(.kind == "pressure" and .name == $name and .status == "pass")] | length == 1' \
    "$OUT_DIR/storage-results.jsonl" >/dev/null || fail "missing storage pressure case: $pressure"
done
jq -s -e '[.[] | select(.kind == "target-layout" and .name == "rd23-ubootmod" and
  .status == "pass" and .details.transition_and_rollback == true)] | length == 1' \
  "$OUT_DIR/storage-results.jsonl" >/dev/null || fail "RD23 ubootmod transition/rollback evidence is missing"

faults=(before-mutation snapshot_ready applying after-premier-router-core
  after-luci-app-premier-router after-premier-router-setup validating committing
  rollback_pending rolling_back rollback-after-premier-router-core
  rollback-after-luci-app-premier-router rollback-after-premier-router-setup
  compatibility-cleanup post-reboot-validation)
for boundary in "${faults[@]}"; do
  jq -s -e --arg boundary "$boundary" '
    [.[] | select(.kind == "power-loss" and .name == $boundary and .status == "pass" and
      .details.injection_marker_consumed == true and .details.protected_state_matches == true and
      (.details.final_state == "committed" or .details.final_state == "rolled_back" or
       .details.final_state == "failed_before_mutation"))] | length == 1
    ' "$OUT_DIR/fault-results.jsonl" >/dev/null || fail "fault boundary missing or unsafe: $boundary"
done

for version in 0.7.9 0.7.10; do
  card="$(find "$EVIDENCE_ROOT" -type f -name "old-worker-$version-visible-card.json" -print | sed -n '1p')"
  [[ -n "$card" ]] && jq -e '.ok == true and .visible_vpn_status_cards == 1' "$card" >/dev/null ||
    fail "exactly-one-visible-status-card evidence is missing for $version"
done

jq -s '.' "$OUT_DIR/vm-measurements.jsonl" > "$OUT_DIR/vm-measurements.json"
jq -s '.' "$OUT_DIR/transition-results.jsonl" > "$OUT_DIR/transition-results.json"
jq -s '.' "$OUT_DIR/fault-results.jsonl" > "$OUT_DIR/fault-results.json"
jq -s '.' "$OUT_DIR/storage-results.jsonl" > "$OUT_DIR/storage-results.json"
jq -n --arg source "$source_sha" --arg baseline "$EXPECTED_BASELINE_DIGEST" \
  --arg fingerprint "$key_fingerprint" --argjson shard_count 4 \
  '{schema_version:1,candidate_source_sha:$source,baseline_pack_digest:$baseline,
    production_public_key_fingerprint:$fingerprint,release_evidence:true,
    individual_shards_authorize_release:false,all_mandatory_cases_passed:true,
    configured_ram_mib:256,maximum_parallel_vm_jobs:2,shard_count:$shard_count,
    physical_rd23_test:"pending-not-authorized"}' > "$OUT_DIR/summary.json"
(cd "$OUT_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
  sed 's#^./##' | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)

printf 'Aggregated mandatory VM evidence passed for %s\n' "$source_sha"
