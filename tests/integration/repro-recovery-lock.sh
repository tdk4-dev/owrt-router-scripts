#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC_PRO_HOST="${ROUTER_UI_MAC_PRO_HOST:-mac-pro-hosting}"
REMOTE_ROOT="${ROUTER_UI_MAC_PRO_ROOT:-/Users/mac-pro-host/Documents/RouterUI-local-repro}"
VM_NAME="${ROUTER_UI_VBOX_VM:-RouterUI-070-Recovery-Repro-20260721}"
SNAPSHOT_NAME="${ROUTER_UI_VBOX_SNAPSHOT:-clean-0.7.0-rd23-stock}"
CANDIDATE_DIR="${ROUTER_UI_CANDIDATE_DIR:-$REMOTE_ROOT/assets/release-v0.7.11-rc.5}"
EXPECTED_SOURCE_SHA="${ROUTER_UI_CANDIDATE_SOURCE_SHA:-}"
REMOTE_SOURCE_ROOT="${ROUTER_UI_MAC_PRO_SOURCE_ROOT:-/Users/mac-pro-host/Documents/RouterUI-release/Premier-Router-0.7.11-rc5-worktree}"
BASELINE_DIR="${ROUTER_UI_MAC_PRO_BASELINE_DIR:-/Users/mac-pro-host/Documents/RouterUI-release/historical-baselines-0.7.x}"
BASELINE_LOCK="${ROUTER_UI_MAC_PRO_BASELINE_LOCK:-$REMOTE_ROOT/runtime/legacy-baseline-lock.json}"
MODE=focused
REPEAT=1

usage() {
  cat <<'EOF'
Usage: ./tests/integration/repro-recovery-lock.sh [--mode focused|bridge] [--repeat N]

Runs the recovery-lock reproducer on the disposable Mac Pro VirtualBox guest.
The focused mode stops after post-reboot commit validation. Bridge mode also
performs exact rollback, reboots again, and validates the restored source.
ROUTER_UI_CANDIDATE_SOURCE_SHA must name the exact signed candidate commit.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      MODE="$2"
      shift 2
      ;;
    --repeat)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      REPEAT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$MODE" = focused || "$MODE" = bridge ]] || {
  printf 'Invalid mode: %s\n' "$MODE" >&2
  exit 2
}
[[ "$REPEAT" =~ ^[1-9][0-9]*$ ]] && (( REPEAT <= 50 )) || {
  printf 'Repeat count must be between 1 and 50\n' >&2
  exit 2
}
[[ "$REMOTE_ROOT" = /Users/mac-pro-host/Documents/RouterUI-local-repro ]] || {
  printf 'Refusing unexpected Mac Pro test root: %s\n' "$REMOTE_ROOT" >&2
  exit 2
}
[[ "$CANDIDATE_DIR" = "$REMOTE_ROOT"/assets/* ]] || {
  printf 'Candidate must be under the isolated Mac Pro asset root\n' >&2
  exit 2
}
[[ "$VM_NAME" =~ ^RouterUI-[A-Za-z0-9._-]+$ ]] || {
  printf 'Refusing unexpected VirtualBox VM name: %s\n' "$VM_NAME" >&2
  exit 2
}
[[ "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'Candidate source SHA is malformed\n' >&2
  exit 2
}
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$EXPECTED_SOURCE_SHA" ]] || {
  printf 'Local harness HEAD differs from the candidate source SHA\n' >&2
  exit 2
}
[[ -z "$(git -C "$ROOT_DIR" status --short)" ]] || {
  printf 'Local harness worktree is dirty; refusing unattributed staged bytes\n' >&2
  exit 2
}

remote_runtime="$REMOTE_ROOT/runtime"
remote_runtime_q="$(printf '%q' "$remote_runtime")"
stage_file() {
  local source="$1" name="$2" mode="$3" destination_q
  destination_q="$(printf '%q' "$remote_runtime/$name")"
  ssh "$MAC_PRO_HOST" \
    "umask 077; mkdir -p $remote_runtime_q; cat > $destination_q; chmod $mode $destination_q" \
    < "$source"
}

stage_file "$ROOT_DIR/tests/integration/repro-recovery-lock-mac-pro.sh" \
  repro-recovery-lock-mac-pro.sh 700
stage_file "$ROOT_DIR/tests/integration/https-artifact-server.rb" \
  https-artifact-server.rb 700
stage_file "$ROOT_DIR/tests/vm/router-ui-vm-guest.sh" \
  router-ui-vm-guest.sh 700

printf 'Mac Pro recovery-lock validation: mode=%s repeat=%s VM=%s snapshot=%s\n' \
  "$MODE" "$REPEAT" "$VM_NAME" "$SNAPSHOT_NAME"
printf 'Immutable candidate source: %s\n' "$EXPECTED_SOURCE_SHA"

remote_command=(
  /bin/bash "$remote_runtime/repro-recovery-lock-mac-pro.sh"
  --mode "$MODE"
  --repeat "$REPEAT"
  --root "$REMOTE_ROOT"
  --vm "$VM_NAME"
  --snapshot "$SNAPSHOT_NAME"
  --candidate "$CANDIDATE_DIR"
  --source-sha "$EXPECTED_SOURCE_SHA"
  --source-root "$REMOTE_SOURCE_ROOT"
  --source-version 0.7.0
  --baseline-dir "$BASELINE_DIR"
  --baseline-lock "$BASELINE_LOCK"
)
printf -v remote_command_q ' %q' "${remote_command[@]}"
ssh "$MAC_PRO_HOST" "${remote_command_q# }"
