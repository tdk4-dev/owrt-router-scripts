#!/bin/bash

# Source-only fail-closed phase runner.  The caller owns set -Eeuo pipefail.
# Output is logged through one exact tee child while the tested command keeps
# its own exit status.  The parent emits failure.json before the caller's
# cleanup trap tears down its exact QEMU/server children.

VM_PHASE_TEE_PID=""
VM_PHASE_FIFO=""
VM_PHASE_LOG=""
VM_PHASE=""
VM_PHASE_COMMAND=""
VM_PHASE_EXECUTOR_PID=""
VM_PHASE_STATE=""
VM_PHASE_TIMEOUT_SECONDS="${ROUTER_UI_VM_PHASE_TIMEOUT_SECONDS:-1800}"

vm_shell_quote_command() {
  local word quoted rendered=""
  for word in "$@"; do
    printf -v quoted '%q' "$word"
    rendered+="${rendered:+ }$quoted"
  done
  printf '%s\n' "$rendered"
}

vm_candidate_mutation_value() {
  if [[ -s "${EVIDENCE_DIR:-}/.phase-candidate-mutation" ]]; then
    sed -n '1p' "$EVIDENCE_DIR/.phase-candidate-mutation"
    return
  fi
  if declare -F vm_candidate_mutation_began >/dev/null; then
    vm_candidate_mutation_began 2>/dev/null || printf 'unknown\n'
  else
    printf '%s\n' "${VM_CANDIDATE_MUTATION_BEGAN:-false}"
  fi
}

vm_write_failure_json() {
  local exit_code="$1" mutation
  mutation="$(vm_candidate_mutation_value)"
  case "$mutation" in true|false) ;; *) mutation=null ;; esac
  mkdir -p "$EVIDENCE_DIR"
  jq -n \
    --arg candidate_sha "${CANDIDATE_SOURCE_SHA:-none-baseline-pack-build}" \
    --arg harness_sha "${HARNESS_SOURCE_SHA:-unknown}" \
    --arg baseline_pack_digest "${BASELINE_PACK_DIGEST:-not-yet-built}" \
    --arg case "${VM_CASE:-${DIAGNOSTIC_CASE:-unknown}}" \
    --arg version "${VM_ACTIVE_VERSION:-${VM_SOURCE_VERSION:-}}" \
    --arg phase "$VM_PHASE" \
    --arg fault_boundary "${VM_FAULT_BOUNDARY:-}" \
    --arg command "$VM_PHASE_COMMAND" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson timeout_seconds "$VM_PHASE_TIMEOUT_SECONDS" \
    --argjson exit_code "$exit_code" \
    --argjson candidate_mutation_began "$mutation" \
    '{schema_version:1,diagnostic:true,release_evidence:false,
      candidate_sha:$candidate_sha,harness_sha:$harness_sha,
      baseline_pack_digest:$baseline_pack_digest,case:$case,version:$version,
      phase:$phase,fault_boundary:(if $fault_boundary == "" then null else $fault_boundary end),
      command:$command,exit_code:$exit_code,
      timeout_seconds:$timeout_seconds,timed_out:($exit_code == 124),
      candidate_mutation_began:$candidate_mutation_began,generated_at:$generated_at}' \
    > "$EVIDENCE_DIR/failure.json"
}

vm_finish_phase_log() {
  if [[ -n "$VM_PHASE_TEE_PID" ]]; then
    wait "$VM_PHASE_TEE_PID"
    VM_PHASE_TEE_PID=""
  fi
  [[ -z "$VM_PHASE_FIFO" ]] || rm -f "$VM_PHASE_FIFO"
  VM_PHASE_FIFO=""
}

vm_phase_child_cleanup() {
  local exit_code="$1"
  trap - EXIT INT TERM
  set +e
  if declare -F vm_candidate_mutation_began >/dev/null; then
    vm_candidate_mutation_began > "$EVIDENCE_DIR/.phase-candidate-mutation" 2>/dev/null || true
  fi
  if [[ -n "${CURRENT_PID:-}" ]]; then
    if [[ "$exit_code" = 124 ]]; then
      jq -n --arg phase "$VM_PHASE" --argjson qemu_pid "$CURRENT_PID" \
        --argjson alive_before_timeout_cleanup "$(kill -0 "$CURRENT_PID" 2>/dev/null && printf true || printf false)" \
        --argjson observed_at_epoch "$(date +%s)" \
        '{schema_version:1,phase:$phase,qemu_pid:$qemu_pid,
          alive_before_timeout_cleanup:$alive_before_timeout_cleanup,
          observed_at_epoch:$observed_at_epoch}' > "$EVIDENCE_DIR/qemu-timeout.json"
    fi
    if kill -0 "$CURRENT_PID" 2>/dev/null && declare -F capture_guest_state >/dev/null; then
      capture_guest_state "timeout-or-phase-failure-$VM_PHASE" >/dev/null 2>&1 || true
    fi
    kill -9 "$CURRENT_PID" 2>/dev/null || true
    wait "$CURRENT_PID" 2>/dev/null || true
    CURRENT_PID=""
  fi
  vm_write_phase_state
  return "$exit_code"
}

vm_write_phase_state() {
  local variable declaration
  : > "$VM_PHASE_STATE"
  for variable in \
    ROOT_DIR VM_MODE RELEASE_DIR X86_IMAGE_ARCHIVE SYNTHETIC_DIR EVIDENCE_DIR \
    VM_CASE DIAGNOSTIC_CASE DIAGNOSTIC_RUN VM_ONLY ALLOW_LEGACY_CONTRACT \
    HARNESS_SOURCE_SHA VM_SOURCE_VERSION \
    VM_ACTIVE_VERSION VM_PHASE_SELECTOR VM_FAULT_BOUNDARY BASELINE_PACK_DIR \
    BASELINE_OUTPUT_DIR BASELINE_PACK_DIGEST BASELINE_SELECTOR \
    BASELINE_ASSET_CACHE_DIR BASELINE_LOCK \
    BASELINE_CONTRACT_DIGEST_SCRIPT BASELINE_CONTRACT_DIGEST FIXTURE_DIR \
    OPENWRT_VERSION SERVER_PORT SSH_PORT HTTP_PORT SERIAL_PORT WORK ORIGIN HOST_ORIGIN \
    STOCK_WRITABLE_KIB STOCK_UBIFS_DF_KIB UBOOTMOD_WRITABLE_KIB UBOOTMOD_UBIFS_DF_KIB \
    CURRENT_PID SERVER_PID BASELINE_VERSIONS FLEET_BASELINE_VERSIONS \
    CANDIDATE_APP_VERSION CANDIDATE_PACKAGE_VERSION CANDIDATE_RELEASE_TAG \
    CANDIDATE_KEY_ID CANDIDATE_KEY_FINGERPRINT SUCCESSOR_APP_VERSION \
    SUCCESSOR_PACKAGE_VERSION SUCCESSOR_RELEASE_TAG DUAL_DAEMON_SAMPLES \
    DUAL_DAEMON_INTERVAL_SECONDS CANDIDATE_CONTRACT_MODE FAULT_BOUNDARIES ssh_base \
    VM_PHASE VM_PHASE_COMMAND VM_PHASE_TIMEOUT_SECONDS VM_PHASE_STATE \
    VM_RECOVERY_TIMEOUT_SECONDS \
    CANDIDATE_SOURCE_SHA NODE_PATH PATH; do
    declaration="$(declare -p "$variable" 2>/dev/null)" || continue
    declaration="${declaration#declare -- }"
    declaration="${declaration#declare -a }"
    declaration="${declaration#declare -A }"
    printf '%s\n' "$declaration" >> "$VM_PHASE_STATE"
  done
}

run_vm_phase() {
  local function_name phase_rc=0
  VM_PHASE="$1"
  shift
  [[ "$VM_PHASE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid phase timeout: %s\n' "$VM_PHASE_TIMEOUT_SECONDS" >&2
    return 2
  }
  VM_PHASE_COMMAND="$(vm_shell_quote_command "$@")"
  VM_PHASE_LOG="$EVIDENCE_DIR/phase-${VM_PHASE//[^A-Za-z0-9_.-]/_}.log"
  VM_PHASE_FIFO="${TMPDIR:-/tmp}/router-ui-vm-phase.$$.fifo"
  VM_PHASE_STATE="${TMPDIR:-/tmp}/router-ui-vm-phase.$$.state"
  rm -f "$VM_PHASE_FIFO"
  mkfifo "$VM_PHASE_FIFO"
  tee "$VM_PHASE_LOG" < "$VM_PHASE_FIFO" &
  VM_PHASE_TEE_PID=$!
  rm -f "$EVIDENCE_DIR/.phase-candidate-mutation"
  printf 'false\n' > "$EVIDENCE_DIR/.phase-candidate-mutation"
  vm_write_phase_state
  while read -r function_name; do
    [[ -n "$function_name" ]] && export -f "$function_name"
  done < <(declare -F | awk '{print $3}')
  python3 -c '
import os, signal, subprocess, sys

deadline = int(sys.argv[1])
state = sys.argv[2]
evidence = sys.argv[3]
phase = sys.argv[4]
command = sys.argv[5:]
script = "source \"$1\"; shift; trap '\''vm_phase_child_cleanup $?'\'' EXIT; trap '\''exit 124'\'' TERM; \"$@\"; [[ -z \"${CURRENT_PID:-}\" ]] || { echo \"phase left owned QEMU PID running: $CURRENT_PID\" >&2; exit 125; }"
proc = subprocess.Popen(
    ["bash", "-Eeuo", "pipefail", "-c", script, "router-ui-phase", state, *command],
    start_new_session=True,
)

def stop(signum, _frame):
    try:
        os.kill(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    result = proc.wait(timeout=deadline)
except subprocess.TimeoutExpired:
    qemu_pid = None
    qemu_pid_path = os.path.join(evidence, "current-qemu.pid")
    try:
        with open(qemu_pid_path, "r", encoding="ascii") as handle:
            qemu_pid = int(handle.read().strip())
    except (FileNotFoundError, ValueError, OSError):
        pass
    if qemu_pid is not None:
        import json, time
        try:
            os.kill(qemu_pid, 0)
            alive = True
        except (ProcessLookupError, PermissionError):
            alive = False
        with open(os.path.join(evidence, "qemu-timeout.json"), "w", encoding="utf-8") as handle:
            json.dump({"schema_version": 1, "phase": phase, "qemu_pid": qemu_pid,
                       "alive_before_timeout_cleanup": alive,
                       "observed_at_epoch": int(time.time())}, handle, sort_keys=True)
            handle.write("\n")
    try:
        os.kill(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    raise SystemExit(124)
raise SystemExit(result if result >= 0 else 128 - result)
' "$VM_PHASE_TIMEOUT_SECONDS" "$VM_PHASE_STATE" "$EVIDENCE_DIR" "$VM_PHASE" "$@" > "$VM_PHASE_FIFO" 2>&1 &
  VM_PHASE_EXECUTOR_PID=$!
  set +e
  wait "$VM_PHASE_EXECUTOR_PID"
  phase_rc=$?
  set -e
  VM_PHASE_EXECUTOR_PID=""
  # The phase shell is isolated so the deadline can own its whole process
  # tree.  Import only the explicit runtime state it wrote on EXIT.
  source "$VM_PHASE_STATE"
  vm_finish_phase_log
  rm -f "$VM_PHASE_STATE"
  VM_PHASE_STATE=""
  if [[ "$phase_rc" -ne 0 ]]; then
    vm_write_failure_json "$phase_rc"
    return "$phase_rc"
  fi
}
