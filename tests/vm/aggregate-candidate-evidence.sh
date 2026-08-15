#!/bin/bash
set -Eeuo pipefail
umask 077

EVIDENCE_ROOT="${EVIDENCE_ROOT:?EVIDENCE_ROOT is required}"
RELEASE_DIR="${RELEASE_DIR:?RELEASE_DIR is required}"
OUT_DIR="${OUT_DIR:?OUT_DIR is required}"
EXPECTED_BASELINE_DIGEST="${EXPECTED_BASELINE_DIGEST:?EXPECTED_BASELINE_DIGEST is required}"

fail() { printf 'CANDIDATE-EVIDENCE-ERROR: %s\n' "$*" >&2; exit 1; }
for tool in find jq sha256sum sort; do command -v "$tool" >/dev/null 2>&1 || fail "missing $tool"; done
[[ -d "$EVIDENCE_ROOT" && -s "$RELEASE_DIR/router-release-manifest.json" &&
  -s "$RELEASE_DIR/SHA256SUMS" ]] ||
  fail "evidence root or release manifest is missing"
[[ "$EXPECTED_BASELINE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "baseline artifact digest is malformed"
(cd "$RELEASE_DIR" && sha256sum -c SHA256SUMS >/dev/null) ||
  fail "final release assets do not match the signed inventory bytes"
mkdir -p "$OUT_DIR"

source_sha="$(jq -er '.source_commit' "$RELEASE_DIR/router-release-manifest.json")"
candidate_app_version="$(jq -er '.app_version' "$RELEASE_DIR/router-release-manifest.json")"
candidate_package_version="$(jq -er '.package_version' "$RELEASE_DIR/router-release-manifest.json")"
candidate_release_tag="$(jq -er '.release_tag' "$RELEASE_DIR/router-release-manifest.json")"
key_id="$(jq -er '.signing_key_id' "$RELEASE_DIR/router-release-manifest.json")"
key_fingerprint="$(jq -er '.signing_key_fingerprint' "$RELEASE_DIR/router-release-manifest.json")"
jq -e '
  .source_dirty == false and .channel == "candidate" and
  .app_version == "0.7.11-rc.11" and .package_version == "0.7.11~rc11-1" and
  .release_tag == "vpn-panel-v0.7.11-rc.11" and
  any(.transitions[]; .source_version == "0.7.11-rc.5" and
    .source_protocol == 2 and .mode == "package-v2-rc") and
  (any(.transitions[]; .source_version == "0.7.11-rc.4" and
    .source_protocol == 2) | not)
' "$RELEASE_DIR/router-release-manifest.json" >/dev/null ||
  fail "release manifest is not the exact RC11 candidate contract"

find "$EVIDENCE_ROOT" -type f -name candidate-content-descriptor.json -print0 |
  LC_ALL=C sort -z | xargs -0 jq -c . > "$OUT_DIR/candidate-content-descriptors.jsonl"
jq -s -e --arg source "$source_sha" --arg key "$key_id" \
  --arg fingerprint "$key_fingerprint" --arg app "$candidate_app_version" \
  --arg package "$candidate_package_version" --arg tag "$candidate_release_tag" '
    length == 4 and all(.[ ];
      .schema_version == 1 and .kind == "router-ui-candidate-content" and
      .immutable == true and .manifested_bytes_verified == true and
      .signatures_verified == true and .product_source_sha == $source and
      .production_key_id == $key and .production_key_fingerprint == $fingerprint and
      .candidate.app_version == $app and .candidate.package_version == $package and
      .candidate.release_tag == $tag and
      .successor.app_version == "0.7.11" and
      .successor.package_version == "0.7.11-1" and
      .successor.release_tag == "vpn-panel-v0.7.11") and
    ([.[].candidate] | unique | length) == 1 and
    ([.[].successor] | unique | length) == 1 and
    all(.[ ];
      (.release_manifest_sha256 | test("^[0-9a-f]{64}$")) and
      (.release_sha256sums_sha256 | test("^[0-9a-f]{64}$")) and
      (.synthetic_manifest_sha256 | test("^[0-9a-f]{64}$")) and
      (.synthetic_sha256sums_sha256 | test("^[0-9a-f]{64}$"))) and
    ([.[].release_manifest_sha256] | unique | length) == 1 and
    ([.[].release_sha256sums_sha256] | unique | length) == 1 and
    ([.[].synthetic_manifest_sha256] | unique | length) == 1 and
    ([.[].synthetic_sha256sums_sha256] | unique | length) == 1
  ' "$OUT_DIR/candidate-content-descriptors.jsonl" >/dev/null ||
  fail "signed candidate/successor content descriptors disagree"
successor_app_version="$(jq -sr '.[0].successor.app_version' \
  "$OUT_DIR/candidate-content-descriptors.jsonl")"
successor_package_version="$(jq -sr '.[0].successor.package_version' \
  "$OUT_DIR/candidate-content-descriptors.jsonl")"
successor_release_tag="$(jq -sr '.[0].successor.release_tag' \
  "$OUT_DIR/candidate-content-descriptors.jsonl")"
candidate_manifest_sha256="$(jq -sr '.[0].release_manifest_sha256' \
  "$OUT_DIR/candidate-content-descriptors.jsonl")"
candidate_inventory_sha256="$(jq -sr '.[0].release_sha256sums_sha256' \
  "$OUT_DIR/candidate-content-descriptors.jsonl")"
successor_manifest_sha256="$(jq -sr '.[0].synthetic_manifest_sha256' \
  "$OUT_DIR/candidate-content-descriptors.jsonl")"
[[ "$(sha256sum "$RELEASE_DIR/router-release-manifest.json" | awk '{print $1}')" = \
  "$candidate_manifest_sha256" ]] ||
  fail "release manifest does not match the immutable candidate descriptor"
[[ "$(sha256sum "$RELEASE_DIR/SHA256SUMS" | awk '{print $1}')" = \
  "$candidate_inventory_sha256" ]] ||
  fail "release inventory does not match the immutable candidate descriptor"

find "$EVIDENCE_ROOT" -type f -name release-contract.json -print0 | LC_ALL=C sort -z |
  xargs -0 jq -c . > "$OUT_DIR/release-contracts.jsonl"
jq -s -e --arg source "$source_sha" --arg key "$key_id" \
  --arg fingerprint "$key_fingerprint" --arg candidate_app "$candidate_app_version" \
  --arg candidate_package "$candidate_package_version" --arg candidate_tag "$candidate_release_tag" \
  --arg candidate_manifest "$candidate_manifest_sha256" --arg successor_app "$successor_app_version" \
  --arg successor_package "$successor_package_version" --arg successor_tag "$successor_release_tag" \
  --arg successor_manifest "$successor_manifest_sha256" '
    length == 23 and all(.[ ];
      .schema_version == 1 and .source_commit == $source and
      .contract_mode == "rc11-active-key" and
      .signing_key_id == $key and .signing_key_fingerprint == $fingerprint and
      .candidate.app_version == $candidate_app and
      .candidate.package_version == $candidate_package and
      .candidate.release_tag == $candidate_tag and
      .candidate.manifest_sha256 == $candidate_manifest and
      .successor.app_version == $successor_app and
      .successor.package_version == $successor_package and
      .successor.release_tag == $successor_tag and
      .successor.manifest_sha256 == $successor_manifest and
      .manifest_signature_files_present == true and
      .signatures_verified_by_harness == false and .hardware_verified == false)
  ' "$OUT_DIR/release-contracts.jsonl" >/dev/null ||
  fail "VM cases did not use the signed manifests bound by their content descriptors"

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
[[ "$(wc -l < "$OUT_DIR/shard-summaries.jsonl" | tr -d ' ')" -eq 23 ]] ||
  fail "expected exactly 23 independently finalized VM case summaries"
jq -s -e --arg source "$source_sha" --arg fingerprint "$key_fingerprint" \
  --arg baseline "$EXPECTED_BASELINE_DIGEST" --arg candidate_app "$candidate_app_version" \
  --arg candidate_package "$candidate_package_version" --arg candidate_tag "$candidate_release_tag" \
  --arg successor_app "$successor_app_version" --arg successor_package "$successor_package_version" \
  --arg successor_tag "$successor_release_tag" '
    length == 23 and all(.[ ];
      .candidate_source_sha == $source and
      .production_public_key_fingerprint == $fingerprint and
      .harness_source_sha == $source and
      .baseline_pack_digest == $baseline and
      .candidate.app_version == $candidate_app and
      .candidate.package_version == $candidate_package and
      .candidate.release_tag == $candidate_tag and
      .successor.app_version == $successor_app and
      .successor.package_version == $successor_package and
      .successor.release_tag == $successor_tag and
      .candidate_contract_mode == "rc11-active-key" and
      .diagnostic == true and .release_evidence == false and
      .configured_ram_mib == 256 and
      .recovery_timeout_seconds == 600 and
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
find "$EVIDENCE_ROOT" -type f -name dual-daemon-evidence.jsonl -print0 | LC_ALL=C sort -z |
  xargs -0 cat > "$OUT_DIR/dual-daemon-evidence.jsonl"
find "$EVIDENCE_ROOT" -type f -name reboot-recovery.jsonl -print0 | LC_ALL=C sort -z |
  xargs -0 cat > "$OUT_DIR/reboot-recovery.jsonl"
jq -s -e '
  length > 0 and all(.[ ];
    .boot_id_changed == true and .transaction_id != null and
    .outcome == "converged" and .timed_out == false and
    .final_state == .expected_terminal_state and .final_lock_present == false and
    (.real_elapsed_seconds | type == "number") and
    (.observations | length) > 0 and
    all(.observations[];
      (.observed_at_epoch | type == "number") and
      (.elapsed_seconds | type == "number") and
      (.state | type == "string") and (.lock_present | type == "boolean")))
  ' "$OUT_DIR/reboot-recovery.jsonl" >/dev/null ||
  fail "reboot recovery readiness evidence is incomplete"

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

jq -s -e --arg app "$candidate_app_version" --arg package "$candidate_package_version" '
  length == 30 and
  ([.[] | select(.phase == "before-reboot")] | length) == 15 and
  ([.[] | select(.phase == "after-reboot")] | length) == 15 and
  ([.[].boot_id] | unique | length) == 2 and
  ([.[] | select(.phase == "before-reboot") | .tailscaled |
    [.pid,.starttime_ticks]] | unique | length) == 1 and
  ([.[] | select(.phase == "before-reboot") | .xray |
    [.pid,.starttime_ticks]] | unique | length) == 1 and
  ([.[] | select(.phase == "after-reboot") | .tailscaled |
    [.pid,.starttime_ticks]] | unique | length) == 1 and
  ([.[] | select(.phase == "after-reboot") | .xray |
    [.pid,.starttime_ticks]] | unique | length) == 1 and
  all(.[ ];
    .app_version == $app and .package_version == $package and
    .mem_total_kib >= 220000 and .mem_total_kib <= 262144 and
    .mem_available_kib >= 16384 and .tmp_free_kib > 0 and .overlay_free_kib > 0 and
    .tailscaled.running == true and .tailscaled.pid > 0 and
    .tailscaled.starttime_ticks > 0 and .tailscaled.rss_kib > 0 and
    .xray.running == true and .xray.pid > 0 and
    .xray.starttime_ticks > 0 and .xray.rss_kib > 0 and
    .xray.loopback_only == true and .xray.traffic_probe_ok == true and
    .router_ui_status_ok == true and .tailscale_local_api_ok == true and
    .tailscale_backend_state == "NeedsLogin" and
    .tailscale_ips_present == false and
    .tailscale_enrollment_observed == "not-enrolled" and
    .oom_detected == false and
    .hardware_verified == false)
' "$OUT_DIR/dual-daemon-evidence.jsonl" >/dev/null ||
  fail "256 MiB dual-daemon VM evidence is incomplete"

require_transition() {
  local kind="$1" name="$2"
  jq -s -e --arg kind "$kind" --arg name "$name" \
    '[.[] | select(.kind == $kind and .name == $name and .status == "pass")] | length == 1' \
    "$OUT_DIR/transition-results.jsonl" >/dev/null || fail "missing transition: $kind $name"
}
for version in 0.7.9 0.7.10; do
  require_transition old-worker "$version->$candidate_app_version->rollback"
done
while IFS= read -r version; do
  require_transition rescue "$version->$candidate_app_version->rollback"
done < <(jq -r --arg candidate "$candidate_app_version" \
  '.transitions[] | select((.mode | contains("rescue")) and .source_version != $candidate) | .source_version' \
  "$RELEASE_DIR/router-release-manifest.json")
for refusal in 0.7.7 unknown 0.7 development 0.7.11RC1 0.8.0 direct-other-target; do
  require_transition refusal "$refusal"
done
require_transition image clean-x86-boot
require_transition protocol-v2 \
  "$candidate_app_version->$successor_app_version->$candidate_app_version->$successor_app_version->$candidate_app_version"
require_transition concurrency cli-rpc-cron
require_transition runtime dual-daemon-256m

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
jq -s -e '
  any(.[]; .kind == "runtime" and .name == "dual-daemon-256m" and
    .details.configured_ram_mib == 256 and .details.samples_per_boot == 15 and
    .details.minimum_mem_available_kib >= 16384 and
    .details.boot_id_changed == true and .details.release_package_set_persisted == true and
    .details.tailscaled_real_process == true and .details.tailscale_enrollment == "not-enrolled" and
    .details.tailscale_enrollment_observed == true and
    .details.tailscale_ips_present == false and
    (.details.tailscale_backend_states | length) > 0 and
    all(.details.tailscale_backend_states[]; . == "NeedsLogin") and
    .details.xray_real_process == true and
    .details.xray_scope == "non-secret-local-loopback-only" and
    .details.oom_detected == false and .details.process_restart_detected == false and
    .details.vm_verified == true and
    .details.rd23_hardware_verified == false)
  ' "$OUT_DIR/transition-results.jsonl" >/dev/null ||
  fail "dual-daemon VM transition evidence is incomplete"

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
jq -s '.' "$OUT_DIR/dual-daemon-evidence.jsonl" > "$OUT_DIR/dual-daemon-evidence.json"
jq -n --arg source "$source_sha" --arg baseline "$EXPECTED_BASELINE_DIGEST" \
  --arg fingerprint "$key_fingerprint" --arg candidate_app "$candidate_app_version" \
  --arg candidate_package "$candidate_package_version" --arg candidate_tag "$candidate_release_tag" \
  --arg successor_app "$successor_app_version" --arg successor_package "$successor_package_version" \
  --arg successor_tag "$successor_release_tag" --argjson shard_count 4 \
  '{schema_version:1,candidate_source_sha:$source,baseline_pack_digest:$baseline,
    production_public_key_fingerprint:$fingerprint,release_evidence:true,
    candidate:{app_version:$candidate_app,package_version:$candidate_package,release_tag:$candidate_tag},
    successor:{app_version:$successor_app,package_version:$successor_package,release_tag:$successor_tag},
    individual_shards_authorize_release:false,all_mandatory_cases_passed:false,
    supplemental_qemu_cases_passed:true,release_authorized:false,
    rc5_rc11_virtualbox_cycle:"pending-mac-pro",same_workstation_browser:"pending-mac-pro",
    configured_ram_mib:256,maximum_parallel_vm_jobs:2,shard_count:$shard_count,
    dual_daemon_vm_verified:true,
    dual_daemon_scope:"real-unenrolled-tailscaled-plus-local-only-xray",
    physical_rd23_test:"pending-not-authorized",hardware_verified:false}' > "$OUT_DIR/summary.json"
(cd "$OUT_DIR" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
  sed 's#^./##' | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)

printf 'Aggregated supplemental QEMU evidence passed for %s; Mac Pro VirtualBox and browser gates remain pending\n' "$source_sha"
