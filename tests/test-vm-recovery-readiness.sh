#!/bin/bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/vm/recovery-readiness.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-recovery-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() { printf 'VM-RECOVERY-TEST: %s\n' "$*" >&2; exit 1; }
mock_now_file="$WORK/now"
mock_observe_file="$WORK/observe"
vm_recovery_now() { sed -n '1p' "$mock_now_file"; sed -i.bak '1d' "$mock_now_file"; rm -f "$mock_now_file.bak"; }
vm_recovery_sleep() { :; }
vm_recovery_observe() { sed -n '1p' "$mock_observe_file"; sed -i.bak '1d' "$mock_observe_file"; rm -f "$mock_observe_file.bak"; }

printf '%s\n' 100 100 101 103 > "$mock_now_file"
printf 'committed_pending_reboot_validation\ttrue\nvalidating\ttrue\ncommitted\tfalse\n' > "$mock_observe_file"
success="$WORK/success.jsonl"
vm_wait_for_recovery "$success" 10 txn-success committed boot-a boot-b
jq -e '
  .before_boot_id == "boot-a" and .after_boot_id == "boot-b" and
  .boot_id_changed == true and .transaction_id == "txn-success" and
  .expected_terminal_state == "committed" and .outcome == "converged" and
  .real_elapsed_seconds == 3 and .final_state == "committed" and
  .final_lock_present == false and .timed_out == false and
  [.observations[].state] ==
    ["committed_pending_reboot_validation","validating","committed"] and
  [.observations[].lock_present] == [true,true,false]
' "$success" >/dev/null || fail 'delayed successful recovery evidence is incomplete'

printf '%s\n' 200 200 201 > "$mock_now_file"
printf 'rolling_back\ttrue\nrollback_failed\ttrue\n' > "$mock_observe_file"
unsafe="$WORK/unsafe.jsonl"
set +e
vm_wait_for_recovery "$unsafe" 10 txn-unsafe committed boot-c boot-d
unsafe_rc=$?
set -e
[[ "$unsafe_rc" = 86 ]] || fail "unsafe recovery exit is $unsafe_rc, expected 86"
jq -e '
  .outcome == "unsafe" and .final_state == "rollback_failed" and
  .real_elapsed_seconds == 1 and .timed_out == false and
  [.observations[].state] == ["rolling_back","rollback_failed"]
' "$unsafe" >/dev/null || fail 'unsafe recovery evidence is incomplete'

printf '%s\n' 300 300 301 302 > "$mock_now_file"
printf 'committed_pending_reboot_validation\ttrue\nvalidating\ttrue\nvalidating\ttrue\n' > "$mock_observe_file"
timed_out="$WORK/timeout.jsonl"
set +e
vm_wait_for_recovery "$timed_out" 2 txn-timeout committed boot-e boot-f
timeout_rc=$?
set -e
[[ "$timeout_rc" = 124 ]] || fail "recovery timeout exit is $timeout_rc, expected 124"
jq -e '
  .outcome == "timeout" and .real_elapsed_seconds == 2 and .timed_out == true and
  .final_state == "validating" and .final_lock_present == true and
  (.observations | length) == 3
' "$timed_out" >/dev/null || fail 'recovery timeout evidence is incomplete'

# A recovery deadline exit must flow through the common phase runner so its
# truthful failure.json and exact owned-child evidence survive cleanup.
source "$ROOT_DIR/tests/vm/fail-closed-runner.sh"
EVIDENCE_DIR="$WORK/phase-timeout-evidence"
mkdir -p "$EVIDENCE_DIR"
VM_PHASE_TIMEOUT_SECONDS=20
VM_CASE=rescue
VM_SOURCE_VERSION=0.7.0
VM_ACTIVE_VERSION=0.7.0
VM_FAULT_BOUNDARY=""
HARNESS_SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BASELINE_PACK_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
CANDIDATE_SOURCE_SHA=cccccccccccccccccccccccccccccccccccccccc
CURRENT_PID=""
capture_guest_state() { printf '%s\n' captured > "$EVIDENCE_DIR/captured-guest-state"; }
mock_recovery_phase_timeout() {
  sleep 60 &
  CURRENT_PID=$!
  printf '%s\n' "$CURRENT_PID" > "$EVIDENCE_DIR/current-qemu.pid"
  return 124
}
set +e
(run_vm_phase recovery-timeout mock_recovery_phase_timeout)
phase_timeout_rc=$?
set -e
[[ "$phase_timeout_rc" = 124 ]] ||
  fail "phase runner timeout exit is $phase_timeout_rc, expected 124"
jq -e '
  .exit_code == 124 and .timed_out == true and .phase == "recovery-timeout" and
  .case == "rescue" and .version == "0.7.0"
' "$EVIDENCE_DIR/failure.json" >/dev/null || fail 'phase timeout failure.json is incomplete'
jq -e '
  .phase == "recovery-timeout" and (.qemu_pid | type == "number") and
  .alive_before_timeout_cleanup == true and (.observed_at_epoch | type == "number")
' "$EVIDENCE_DIR/qemu-timeout.json" >/dev/null || fail 'exact QEMU timeout evidence is incomplete'
[[ -s "$EVIDENCE_DIR/captured-guest-state" ]] || fail 'timeout did not preserve guest evidence'

printf '%s\n' 'VM recovery readiness deadline tests passed.'
