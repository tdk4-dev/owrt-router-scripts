#!/bin/bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGGREGATOR="$ROOT_DIR/tests/vm/aggregate-candidate-evidence.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-aggregate-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

SOURCE=cccccccccccccccccccccccccccccccccccccccc
KEY_ID=production-2026-07
FINGERPRINT=d055711acf1d9a5b
BASELINE=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SUCCESSOR_MANIFEST_HASH=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
SUCCESSOR_INVENTORY_HASH=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
RELEASE="$TMP_ROOT/release"
EVIDENCE="$TMP_ROOT/evidence"
OUT="$TMP_ROOT/out"
mkdir -p "$RELEASE" "$EVIDENCE"

jq -n --arg source "$SOURCE" --arg key "$KEY_ID" --arg fingerprint "$FINGERPRINT" '
  {source_commit:$source,source_dirty:false,channel:"candidate",
   app_version:"0.7.11-rc.5",package_version:"0.7.11~rc5-1",
   release_tag:"vpn-panel-v0.7.11-rc.5",signing_key_id:$key,
   signing_key_fingerprint:$fingerprint,transitions:
    (["0.5.1","0.5.2","0.6.0","0.7.0","0.7.1","0.7.2","0.7.3",
      "0.7.4","0.7.5","0.7.6","0.7.8","0.7.9","0.7.10"] |
      map({mode:"rescue",source_version:.}))}
  ' > "$RELEASE/router-release-manifest.json"
(cd "$RELEASE" && sha256sum router-release-manifest.json > SHA256SUMS)
CANDIDATE_MANIFEST_HASH="$(sha256sum "$RELEASE/router-release-manifest.json" | awk '{print $1}')"
CANDIDATE_INVENTORY_HASH="$(sha256sum "$RELEASE/SHA256SUMS" | awk '{print $1}')"

for index in $(seq 1 23); do
  case_dir="$EVIDENCE/case-$index"
  mkdir -p "$case_dir"
  jq -n --arg source "$SOURCE" --arg baseline "$BASELINE" --arg fingerprint "$FINGERPRINT" '
    {candidate_source_sha:$source,production_public_key_fingerprint:$fingerprint,
     harness_source_sha:$source,baseline_pack_digest:$baseline,diagnostic:true,
     release_evidence:false,configured_ram_mib:256,recovery_timeout_seconds:600,
     candidate_contract_mode:"rc5-active-key",
     vm_execution_mode:"strictly-serial-exact-child-pid",
     candidate:{app_version:"0.7.11-rc.5",package_version:"0.7.11~rc5-1",
       release_tag:"vpn-panel-v0.7.11-rc.5"},
     successor:{app_version:"0.7.11",package_version:"0.7.11-1",
       release_tag:"vpn-panel-v0.7.11"},
     storage_profiles:{"rd23-stock":{writable_backing_kib:54436,
       expected_ubifs_df_total_kib:51352},"rd23-ubootmod":{writable_backing_kib:80352,
       expected_ubifs_df_total_kib:76728}}}
    ' > "$case_dir/summary.json"
  jq -n --arg source "$SOURCE" --arg key "$KEY_ID" --arg fingerprint "$FINGERPRINT" \
    --arg candidate_hash "$CANDIDATE_MANIFEST_HASH" --arg successor_hash "$SUCCESSOR_MANIFEST_HASH" '
    {schema_version:1,source_commit:$source,contract_mode:"rc5-active-key",signing_key_id:$key,
     signing_key_fingerprint:$fingerprint,
     candidate:{app_version:"0.7.11-rc.5",package_version:"0.7.11~rc5-1",
       release_tag:"vpn-panel-v0.7.11-rc.5",manifest_sha256:$candidate_hash},
     successor:{app_version:"0.7.11",package_version:"0.7.11-1",
       release_tag:"vpn-panel-v0.7.11",manifest_sha256:$successor_hash},
     manifest_signature_files_present:true,signatures_verified_by_harness:false,
     hardware_verified:false}
    ' > "$case_dir/release-contract.json"
  jq -nc '{profile:"rd23-stock",configured_ram_mib:256,mem_total_kib:235968,
    tmp_ram_backed:true,overlay_total_kib:51352,overlay_backing_kib:54436,
    target_expected_ubifs_df_total_kib:51352}' > "$case_dir/vm-measurements.jsonl"
  : > "$case_dir/transition-results.jsonl"
  : > "$case_dir/fault-results.jsonl"
  : > "$case_dir/storage-results.jsonl"
done

jq -nc '{schema_version:1,before_boot_id:"boot-old",after_boot_id:"boot-new",
  boot_id_changed:true,transaction_id:"tx",expected_terminal_state:"committed",
  outcome:"converged",real_elapsed_seconds:17,final_state:"committed",
  final_lock_present:false,timed_out:false,
  observations:[{observed_at_epoch:100,elapsed_seconds:0,
    state:"committed_pending_reboot_validation",lock_present:true},
    {observed_at_epoch:117,elapsed_seconds:17,state:"committed",lock_present:false}]}' \
  > "$EVIDENCE/case-1/reboot-recovery.jsonl"

for pair in '1 legacy' '2 protocol-concurrency-storage' '3 faults-a' '4 faults-b'; do
  set -- $pair
  jq -n --arg shard "$2" --arg source "$SOURCE" \
    '{schema_version:1,shard:$shard,candidate_source_sha:$source,complete:true}' \
    > "$EVIDENCE/case-$1/shard-identity.json"
  jq -n --arg source "$SOURCE" --arg key "$KEY_ID" --arg fingerprint "$FINGERPRINT" \
    --arg release_hash "$CANDIDATE_MANIFEST_HASH" \
    --arg release_inventory_hash "$CANDIDATE_INVENTORY_HASH" \
    --arg synthetic_hash "$SUCCESSOR_MANIFEST_HASH" \
    --arg synthetic_inventory_hash "$SUCCESSOR_INVENTORY_HASH" '
    {schema_version:1,kind:"router-ui-candidate-content",immutable:true,
     manifested_bytes_verified:true,signatures_verified:true,product_source_sha:$source,
     production_key_id:$key,production_key_fingerprint:$fingerprint,
     candidate:{app_version:"0.7.11-rc.5",package_version:"0.7.11~rc5-1",
       release_tag:"vpn-panel-v0.7.11-rc.5"},
     successor:{app_version:"0.7.11",package_version:"0.7.11-1",
       release_tag:"vpn-panel-v0.7.11"},release_manifest_sha256:$release_hash,
     release_sha256sums_sha256:$release_inventory_hash,
     synthetic_manifest_sha256:$synthetic_hash,
     synthetic_sha256sums_sha256:$synthetic_inventory_hash}
    ' > "$EVIDENCE/case-$1/candidate-content-descriptor.json"
done

case_one="$EVIDENCE/case-1"
jq -nc '{profile:"rd23-ubootmod",configured_ram_mib:256,mem_total_kib:235968,
  tmp_ram_backed:true,overlay_total_kib:76728,overlay_backing_kib:80352,
  target_expected_ubifs_df_total_kib:76728}' >> "$case_one/vm-measurements.jsonl"
for version in 0.7.9 0.7.10; do
  jq -nc --arg name "$version->0.7.11-rc.5->rollback" '
    {kind:"old-worker",name:$name,status:"pass",details:{transaction:"tx",
     disk_before:{},disk_candidate:{},disk_committed:{},disk_rolled_back:{},disk_after_reboot:{}}}
    ' >> "$case_one/transition-results.jsonl"
  jq -n '{ok:true,visible_vpn_status_cards:1}' > "$case_one/old-worker-$version-visible-card.json"
done
for version in 0.5.1 0.5.2 0.6.0 0.7.0 0.7.1 0.7.2 0.7.3 0.7.4 0.7.5 0.7.6 0.7.8 0.7.9 0.7.10; do
  jq -nc --arg name "$version->0.7.11-rc.5->rollback" '
    {kind:"rescue",name:$name,status:"pass",details:{transaction:"tx",
     disk_before:{},disk_candidate:{},disk_committed:{},disk_rolled_back:{},
     disk_after_rollback_reboot:{}}}
    ' >> "$case_one/transition-results.jsonl"
done
for refusal in 0.7.7 unknown 0.7 development 0.7.11RC1 0.8.0 direct-other-target; do
  jq -nc --arg name "$refusal" '{kind:"refusal",name:$name,status:"pass",details:{}}' \
    >> "$case_one/transition-results.jsonl"
done
jq -nc '{kind:"image",name:"clean-x86-boot",status:"pass",details:{}}' \
  >> "$case_one/transition-results.jsonl"
jq -nc '{kind:"protocol-v2",name:"0.7.11-rc.5->0.7.11->0.7.11-rc.5->0.7.11->0.7.11-rc.5",
  status:"pass",details:{protected_state_matches:true,retained_directories:4}}' \
  >> "$case_one/transition-results.jsonl"
jq -nc '{kind:"concurrency",name:"cli-rpc-cron",status:"pass",details:{}}' \
  >> "$case_one/transition-results.jsonl"
jq -nc '{kind:"runtime",name:"dual-daemon-256m",status:"pass",
  details:{configured_ram_mib:256,samples_per_boot:15,boot_id_changed:true,
    minimum_mem_available_kib:81920,process_restart_detected:false,
    release_package_set_persisted:true,tailscaled_real_process:true,
    tailscale_enrollment:"not-enrolled",tailscale_enrollment_observed:true,
    tailscale_backend_states:["NeedsLogin"],tailscale_ips_present:false,
    xray_real_process:true,
    xray_scope:"non-secret-local-loopback-only",oom_detected:false,
    vm_verified:true,rd23_hardware_verified:false}}' >> "$case_one/transition-results.jsonl"

for phase in before-reboot after-reboot; do
  for sample in $(seq 1 15); do
    jq -nc --arg phase "$phase" --arg boot "boot-$phase" '
      {phase:$phase,boot_id:$boot,app_version:"0.7.11-rc.5",
       package_version:"0.7.11~rc5-1",mem_total_kib:235968,mem_available_kib:81920,
       tmp_free_kib:65536,overlay_free_kib:32768,
       tailscaled:{running:true,pid:101,starttime_ticks:1001,rss_kib:65536},
       xray:{running:true,pid:202,starttime_ticks:2002,rss_kib:49152,
         loopback_only:true,traffic_probe_ok:true},
       router_ui_status_ok:true,tailscale_local_api_ok:true,
       tailscale_backend_state:"NeedsLogin",tailscale_ips_present:false,
       tailscale_enrollment_observed:"not-enrolled",
       oom_detected:false,hardware_verified:false}'
  done
done > "$case_one/dual-daemon-evidence.jsonl"

for name in normal-success slightly-above-reservation below-reservation-refusal; do
  jq -nc --arg name "$name" '{kind:"pressure",name:$name,status:"pass",details:{}}' \
    >> "$case_one/storage-results.jsonl"
done
jq -nc '{kind:"target-layout",name:"rd23-ubootmod",status:"pass",
  details:{transition_and_rollback:true}}' >> "$case_one/storage-results.jsonl"

faults=(before-mutation snapshot_ready applying after-premier-router-core
  after-luci-app-premier-router after-premier-router-setup validating committing
  rollback_pending rolling_back rollback-after-premier-router-core
  rollback-after-luci-app-premier-router rollback-after-premier-router-setup
  compatibility-cleanup post-reboot-validation)
for boundary in "${faults[@]}"; do
  jq -nc --arg name "$boundary" '{kind:"power-loss",name:$name,status:"pass",
    details:{injection_marker_consumed:true,protected_state_matches:true,final_state:"rolled_back"}}' \
    >> "$case_one/fault-results.jsonl"
done

for case_dir in "$EVIDENCE"/case-*; do
  (cd "$case_dir" && find . -maxdepth 1 -type f ! -name SHA256SUMS -print | LC_ALL=C sort |
    sed 's#^./##' | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)
done

EVIDENCE_ROOT="$EVIDENCE" RELEASE_DIR="$RELEASE" OUT_DIR="$OUT" \
  EXPECTED_BASELINE_DIGEST="$BASELINE" "$AGGREGATOR" >/dev/null
jq -e --arg source "$SOURCE" '
  .candidate_source_sha == $source and .release_evidence == true and
  .individual_shards_authorize_release == false and
  .all_mandatory_cases_passed == true and .maximum_parallel_vm_jobs == 2
  ' "$OUT/summary.json" >/dev/null

printf 'Candidate VM evidence aggregation contract passed\n'
