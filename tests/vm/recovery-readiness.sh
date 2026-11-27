#!/bin/bash

# Source-only wall-clock recovery convergence helper. The caller provides
# vm_recovery_observe(), which must print: <state><TAB><lock-present>.

vm_recovery_now() { date +%s; }
vm_recovery_sleep() { sleep "$1"; }

vm_write_recovery_summary() {
  local evidence_file="$1" observations_file="$2" before_boot_id="$3"
  local after_boot_id="$4" transaction="$5" expected_state="$6"
  local outcome="$7" elapsed_seconds="$8" final_state="$9"
  local final_lock_present="${10}" timed_out="${11}"
  jq -cn --slurpfile observations "$observations_file" \
    --arg before_boot_id "$before_boot_id" --arg after_boot_id "$after_boot_id" \
    --arg transaction "$transaction" --arg expected_state "$expected_state" \
    --arg outcome "$outcome" --arg final_state "$final_state" \
    --argjson elapsed_seconds "$elapsed_seconds" \
    --argjson final_lock_present "$final_lock_present" \
    --argjson timed_out "$timed_out" \
    '{schema_version:1,before_boot_id:$before_boot_id,after_boot_id:$after_boot_id,
      boot_id_changed:($before_boot_id != $after_boot_id),transaction_id:$transaction,
      expected_terminal_state:$expected_state,outcome:$outcome,
      real_elapsed_seconds:$elapsed_seconds,final_state:$final_state,
      final_lock_present:$final_lock_present,timed_out:$timed_out,
      observations:$observations}' >> "$evidence_file"
}

vm_wait_for_recovery() {
  local evidence_file="$1" timeout_seconds="$2" transaction="$3"
  local expected_state="$4" before_boot_id="$5" after_boot_id="$6"
  local started_at deadline now elapsed state lock_present observation
  local observations_file final_state=missing final_lock_present=false

  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 2
  mkdir -p "$(dirname "$evidence_file")"
  observations_file="$(mktemp "$(dirname "$evidence_file")/.recovery-observations.XXXXXX")"
  started_at="$(vm_recovery_now)"
  deadline=$((started_at + timeout_seconds))

  while :; do
    now="$(vm_recovery_now)"
    elapsed=$((now - started_at))
    observation="$(vm_recovery_observe "$transaction")" || {
      rm -f "$observations_file"
      return 3
    }
    state="${observation%%$'\t'*}"
    lock_present="${observation#*$'\t'}"
    [[ "$lock_present" = true || "$lock_present" = false ]] || {
      rm -f "$observations_file"
      return 4
    }
    final_state="$state"
    final_lock_present="$lock_present"
    jq -cn --argjson observed_at_epoch "$now" --argjson elapsed_seconds "$elapsed" \
      --arg state "$state" --argjson lock_present "$lock_present" \
      '{observed_at_epoch:$observed_at_epoch,elapsed_seconds:$elapsed_seconds,
        state:$state,lock_present:$lock_present}' >> "$observations_file"

    case "$state" in
      rollback_failed|recovery_required)
        vm_write_recovery_summary "$evidence_file" "$observations_file" \
          "$before_boot_id" "$after_boot_id" "$transaction" "$expected_state" \
          unsafe "$elapsed" "$state" "$lock_present" false
        rm -f "$observations_file"
        return 86
        ;;
    esac
    if [[ "$state" = "$expected_state" && "$lock_present" = false ]]; then
      vm_write_recovery_summary "$evidence_file" "$observations_file" \
        "$before_boot_id" "$after_boot_id" "$transaction" "$expected_state" \
        converged "$elapsed" "$state" "$lock_present" false
      rm -f "$observations_file"
      return 0
    fi
    case "$state" in
      committed|rolled_back|failed_before_mutation)
        if [[ "$lock_present" = false ]]; then
          vm_write_recovery_summary "$evidence_file" "$observations_file" \
            "$before_boot_id" "$after_boot_id" "$transaction" "$expected_state" \
            unexpected_terminal "$elapsed" "$state" "$lock_present" false
          rm -f "$observations_file"
          return 87
        fi
        ;;
    esac
    if (( now >= deadline )); then
      vm_write_recovery_summary "$evidence_file" "$observations_file" \
        "$before_boot_id" "$after_boot_id" "$transaction" "$expected_state" \
        timeout "$elapsed" "$final_state" "$final_lock_present" true
      rm -f "$observations_file"
      return 124
    fi
    vm_recovery_sleep 1
  done
}
