#!/bin/bash
set -euo pipefail
umask 077

VBOXMANAGE=/usr/local/bin/VBoxManage
REMOTE_ROOT=/Users/mac-pro-host/Documents/RouterUI-local-repro
VM_NAME=RouterUI-070-Recovery-Repro-20260721
SNAPSHOT_NAME=clean-0.7.0-rd23-stock
BASELINE_DIR=/Users/mac-pro-host/Documents/RouterUI-release/historical-baselines-0.7.x
SOURCE_ROOT="${SOURCE_ROOT:?SOURCE_ROOT is required}"
CANDIDATE_DIR="${CANDIDATE_DIR:?CANDIDATE_DIR is required}"
NEXT_CANDIDATE_DIR="${NEXT_CANDIDATE_DIR:?NEXT_CANDIDATE_DIR is required}"
EXPECTED_SOURCE_SHA="${EXPECTED_SOURCE_SHA:?EXPECTED_SOURCE_SHA is required}"
CONTROLLER="$SOURCE_ROOT/tests/integration/repro-recovery-lock-mac-pro.sh"
BASELINE_LOCK="$REMOTE_ROOT/runtime/legacy-baseline-lock.json"

fail() { printf 'MATRIX-ERROR: %s\n' "$*" >&2; exit 1; }
[[ -x "$VBOXMANAGE" && -x "$CONTROLLER" ]] || fail 'VirtualBox or matrix controller is unavailable'
[[ "$SOURCE_ROOT" = /Users/mac-pro-host/Documents/RouterUI-release/Premier-Router-0.7.11-rc8-worktree ]]
[[ "$CANDIDATE_DIR" = "$REMOTE_ROOT"/assets/* ]]
[[ "$NEXT_CANDIDATE_DIR" = "$REMOTE_ROOT"/assets/* ]]
[[ "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" = "$EXPECTED_SOURCE_SHA" ]]
[[ -z "$(git -C "$SOURCE_ROOT" status --short)" ]]

factory_state="$($VBOXMANAGE showvminfo premier-router-factory --machinereadable | sed -n 's/^VMState="\([^"]*\)"/\1/p')"
[[ "$factory_state" != running ]] || fail 'premier-router-factory must be stopped or suspended before the RouterUI matrix'
running_routerui="$($VBOXMANAGE list runningvms | awk -F'"' '$2 ~ /^RouterUI-/ {print $2}')"
[[ -z "$running_routerui" ]] || fail "RouterUI VM already running: $running_routerui"

run_source() {
  local version="$1"
  local args=(--mode bridge --repeat 1 --root "$REMOTE_ROOT" \
    --vm "$VM_NAME" --snapshot "$SNAPSHOT_NAME" --candidate "$CANDIDATE_DIR" \
    --source-root "$SOURCE_ROOT" \
    --source-sha "$EXPECTED_SOURCE_SHA" --source-version "$version" \
    --baseline-dir "$BASELINE_DIR" --baseline-lock "$BASELINE_LOCK")
  case "$version" in 0.7.0|0.7.1|0.7.10) args+=(--rollback) ;; esac
  [[ "$version" != 0.7.8 ]] || args+=(--next-candidate "$NEXT_CANDIDATE_DIR")
  "$CONTROLLER" "${args[@]}"
}

for version in 0.7.0 0.7.1 0.7.2 0.7.3 0.7.4 0.7.5 0.7.6 0.7.8 0.7.9 0.7.10; do
  run_source "$version"
done

"$CONTROLLER" --mode bridge --repeat 1 --root "$REMOTE_ROOT" \
  --vm "$VM_NAME" --snapshot "$SNAPSHOT_NAME" --candidate "$CANDIDATE_DIR" \
  --source-root "$SOURCE_ROOT" \
  --source-sha "$EXPECTED_SOURCE_SHA" --source-version 0.7.6 \
  --baseline-dir "$BASELINE_DIR" --baseline-lock "$BASELINE_LOCK" \
  --failure-injection

[[ "$($VBOXMANAGE showvminfo "$VM_NAME" --machinereadable | sed -n 's/^VMState="\([^"]*\)"/\1/p')" = poweroff ]] ||
  fail 'RouterUI validation VM is not powered off after the matrix'
[[ "$($VBOXMANAGE showvminfo "$VM_NAME" --machinereadable | sed -n 's/^CurrentSnapshotName="\([^"]*\)"/\1/p')" = "$SNAPSHOT_NAME" ]] ||
  fail 'RouterUI validation VM was not restored to the clean snapshot'
[[ -z "$($VBOXMANAGE list runningvms | awk -F'"' '$2 ~ /^RouterUI-/ {print $2}')" ]] ||
  fail 'a RouterUI validation VM is still running'

printf 'VirtualBox historical rescue matrix and injected-failure scenario passed\n'
