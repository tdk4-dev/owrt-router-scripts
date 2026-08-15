#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-operation-jobs.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$FAKE_ROOT/usr/share/vpn-ui" "$FAKE_ROOT/usr/share/premier-router" \
  "$FAKE_ROOT/proc/sys/kernel/random" "$FAKE_ROOT/proc/$$" "$FAKE_ROOT/root" "$FAKE_ROOT/tmp" \
  "$FAKE_ROOT/etc"
printf '%s\n' '0.7.11-rc.13' > "$FAKE_ROOT/usr/share/vpn-ui/version"
printf '%s\n' 'UPDATER_PROTOCOL=2' 'PACKAGE_VERSION=0.7.11~rc13-1' > \
  "$FAKE_ROOT/usr/share/premier-router/build-info"
printf '%s\n' fixture-boot > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
printf '%s\n' "AUTO_UPDATE='0'" "AUTO_SCHEDULE='Sunday 04:17'" > "$FAKE_ROOT/etc/vpn-ui-update.conf"
printf '%s\n' '1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 4242' > \
  "$FAKE_ROOT/proc/$$/stat"

PREMIER_ROUTER_HOST_TEST=1
VPN_UI_ROOT_PREFIX="$FAKE_ROOT"
VPN_UI_UPDATE_LIB="$LIB"
VPN_UI_UPDATE_SOURCE_ONLY=1
VPN_UI_RANDOM_SOURCE=/dev/urandom
export PREMIER_ROUTER_HOST_TEST VPN_UI_ROOT_PREFIX VPN_UI_UPDATE_LIB
export VPN_UI_UPDATE_SOURCE_ONLY VPN_UI_RANDOM_SOURCE
. "$UPDATER"

# A historical committed install remains visible in generic page status.
J_TRANSACTION_ID=historical-install
TXN_DIR="$PERSIST_ROOT/$J_TRANSACTION_ID"
JOURNAL="$TXN_DIR/state.json"
mkdir -p "$TXN_DIR"
J_SOURCE_APP_VERSION=0.7.10
J_SOURCE_PACKAGE_VERSION=0.7.10-1
J_SOURCE_UPDATER_PROTOCOL=2
J_SOURCE_TYPE=ipk
J_TARGET_APP_VERSION=0.7.11-rc.13
J_TARGET_PACKAGE_VERSION=0.7.11~rc13-1
J_TARGET_TAG=vpn-panel-v0.7.11-rc.13
J_TARGET_MANIFEST_HASH="$(printf old | sha256sum | awk '{print $1}')"
J_STATE=committed
J_LAST_COMPLETED_STATE=committed_pending_reboot_validation
J_MUTATION_STARTED=true
J_BACKUP_PATH=''
J_ROLLBACK_BUNDLE_PATH=''
J_ROLLBACK_STATUS=not_started
J_ERROR_CLASS=''
J_ERROR_CODE=''
J_ERROR_MESSAGE=''
J_CREATED_AT=2026-08-13T00:00:00Z
J_UPDATED_AT="$J_CREATED_AT"
J_BOOT_ID=historical-boot
J_WORKER_TOKEN=historical-worker
J_OPERATION_JOB_ID=''
J_INVOCATION=manual
J_NEEDS_REBOOT_VALIDATION=false
journal_write
printf '%s\n' "$J_TRANSACTION_ID" | atomic_from_stdin "$ACTIVE_FILE"
status_json > "$TMP_ROOT/generic.json"
jq -e '.job.status == "success" and .job.stage == "committed"' "$TMP_ROOT/generic.json" >/dev/null

# A fresh exact job cannot be satisfied by that old committed journal.
check_one="$(random_token)"
check_two="$(random_token)"
[ "$check_one" != "$check_two" ]
job_create "$check_one" check
job_assign_worker "$check_one" "$$" 4242
job_running "$check_one"
job_status_json "$check_one" check > "$TMP_ROOT/check-running.json"
jq -e --arg id "$check_one" '.job.id == $id and .job.kind == "check" and .job.status == "running"' \
  "$TMP_ROOT/check-running.json" >/dev/null

job_succeed_check "$check_one" 0.7.11 2026-08-15T09:00:00Z
job_status_json "$check_one" check > "$TMP_ROOT/check-succeeded.json"
jq -e --arg id "$check_one" '.job.id == $id and .job.status == "succeeded" and
  .job.checked_at == "2026-08-15T09:00:00Z" and .job.target == "0.7.11"' \
  "$TMP_ROOT/check-succeeded.json" >/dev/null

job_create "$check_two" check
job_assign_worker "$check_two" "$$" 4242
job_running "$check_two"
job_status_json "$check_two" check > "$TMP_ROOT/check-two-running.json"
jq -e --arg first "$check_one" --arg second "$check_two" '
  .job.id == $second and .job.id != $first and .job.status == "running"' \
  "$TMP_ROOT/check-two-running.json" >/dev/null
job_fail "$check_two" discovery_failed 'update discovery failed'
job_status_json "$check_two" check > "$TMP_ROOT/check-two-failed.json"
jq -e '.job.status == "failed" and .job.error_code == "discovery_failed"' \
  "$TMP_ROOT/check-two-failed.json" >/dev/null

# The real worker entrypoint transitions only its own exact record on success and failure.
worker_success="$(random_token)"
lock_acquire "$worker_success"
job_create "$worker_success" check
job_assign_worker "$worker_success" "$$" 4242
discover_release() {
  mkdir -p "$CACHE_DIR"
  printf '%s\n' 2026-08-15T09:30:00Z > "$CACHE_DIR/checked-at"
  printf '%s\n' 0.7.11
}
check_worker "$worker_success"
job_status_json "$worker_success" check > "$TMP_ROOT/worker-success.json"
jq -e '.job.status == "succeeded" and .job.checked_at == "2026-08-15T09:30:00Z"' \
  "$TMP_ROOT/worker-success.json" >/dev/null

worker_failure="$(random_token)"
lock_acquire "$worker_failure"
job_create "$worker_failure" check
job_assign_worker "$worker_failure" "$$" 4242
discover_release() { return 1; }
if check_worker "$worker_failure"; then
  printf '%s\n' 'injected discovery failure unexpectedly succeeded' >&2
  exit 1
fi
job_status_json "$worker_failure" check > "$TMP_ROOT/worker-failure.json"
jq -e '.job.status == "failed" and .job.error_code == "discovery_failed"' \
  "$TMP_ROOT/worker-failure.json" >/dev/null

# Malformed, unknown, wrong-kind, and post-handshake worker death fail closed.
job_status_json bad check > "$TMP_ROOT/malformed.json" 2>/dev/null || true
jq -e '.ok == false and .error_code == "malformed_job_id"' "$TMP_ROOT/malformed.json" >/dev/null
unknown="$(printf unknown | sha256sum | awk '{print $1}')"
job_status_json "$unknown" check > "$TMP_ROOT/unknown.json" 2>/dev/null || true
jq -e '.ok == false and .error_code == "unknown_job_id"' "$TMP_ROOT/unknown.json" >/dev/null
malformed_record="$(printf malformed-record | sha256sum | awk '{print $1}')"
printf '%s\n' '{broken-json' > "$JOB_DIR/$malformed_record.json"
job_status_json "$malformed_record" check > "$TMP_ROOT/malformed-record.json" 2>/dev/null || true
jq -e '.ok == false and .error_code == "unknown_job_id"' "$TMP_ROOT/malformed-record.json" >/dev/null
symlink_record="$(printf symlink-record | sha256sum | awk '{print $1}')"
ln -s "$TMP_ROOT/manifest-does-not-exist" "$JOB_DIR/$symlink_record.json"
job_status_json "$symlink_record" check > "$TMP_ROOT/symlink-record.json" 2>/dev/null || true
jq -e '.ok == false and .error_code == "unknown_job_id"' "$TMP_ROOT/symlink-record.json" >/dev/null
job_status_json "$check_one" apply > "$TMP_ROOT/wrong-kind.json" 2>/dev/null || true
jq -e '.ok == false and .error_code == "wrong_job_kind"' "$TMP_ROOT/wrong-kind.json" >/dev/null
dead="$(random_token)"
job_create "$dead" check
job_assign_worker "$dead" 999999 dead-start
job_running "$dead"
job_status_json "$dead" check > "$TMP_ROOT/dead.json"
jq -e '.job.status == "failed" and .job.error_code == "worker_exited"' "$TMP_ROOT/dead.json" >/dev/null

# Apply identity binds to the exact transaction and remains correlated across reboot recovery.
apply_id="$(random_token)"
job_create "$apply_id" apply
job_assign_worker "$apply_id" "$$" 4242
job_running "$apply_id"
ACTIVE_JOB_ID="$apply_id"
LOCK_TOKEN="$apply_id"
cat > "$TMP_ROOT/manifest.json" <<'EOF'
{"app_version":"0.7.11-rc.14","package_version":"0.7.11~rc14-1","release_tag":"vpn-panel-v0.7.11-rc.14"}
EOF
detect_source_type() { printf legacy; }
source_protocol() { printf 2; }
source_package_version() { printf '0.7.11~rc13-1'; }
transaction_init "$TMP_ROOT/manifest.json" manual
job_status_json "$apply_id" apply > "$TMP_ROOT/apply-bound.json"
jq -e --arg id "$apply_id" '.job.id == $id and (.job.transaction_id | length) > 0 and
  .job.status == "running"' "$TMP_ROOT/apply-bound.json" >/dev/null
set_state committed_pending_reboot_validation
job_status_json "$apply_id" apply > "$TMP_ROOT/apply-pending.json"
jq -e '.job.status == "pending_reboot" and (.job.transaction_id | length) > 0' \
  "$TMP_ROOT/apply-pending.json" >/dev/null
printf '%s\n' changed-boot > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
cleanup_compatibility() { return 0; }
cleanup_package_conffile_artifacts() { return 0; }
target_state_validate() { return 0; }
cleanup_successful_storage() { return 0; }
recover_transaction
job_status_json "$apply_id" apply > "$TMP_ROOT/apply-committed.json"
jq -e '.job.status == "succeeded" and (.job.completed_at | length) > 0' \
  "$TMP_ROOT/apply-committed.json" >/dev/null
journal_load "$JOURNAL"
[ "$J_OPERATION_JOB_ID" = "$apply_id" ]
[ "$J_STATE" = committed ]

# Job files stay private and terminal retention remains bounded.
mode="$(stat -c '%a' "$JOB_DIR/$apply_id.json" 2>/dev/null ||
  stat -f '%Lp' "$JOB_DIR/$apply_id.json")"
[ "$mode" = 600 ]
index=0
while [ "$index" -lt 20 ]; do
  retained="$(random_token)"
  job_create "$retained" check
  job_fail "$retained" retained-test 'bounded retention fixture'
  index=$((index + 1))
done
terminal_count=0
for record in "$JOB_DIR"/*.json; do
  [ -f "$record" ] && [ ! -L "$record" ] || continue
  record_id="${record##*/}"; record_id="${record_id%.json}"
  valid_job_id "$record_id" && job_load "$record_id" || continue
  case "$JOB_STATE" in succeeded|failed) terminal_count=$((terminal_count + 1)) ;; esac
done
[ "$terminal_count" -le "$JOB_RETAIN" ]

printf '%s\n' 'Updater operation identity, stale-state isolation, failure, and reboot correlation checks passed'
