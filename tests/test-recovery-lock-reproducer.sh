#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT_DIR/tests/integration/repro-recovery-lock.sh"
CONTROLLER="$ROOT_DIR/tests/integration/repro-recovery-lock-mac-pro.sh"
SERVER="$ROOT_DIR/tests/integration/https-artifact-server.rb"

for file in "$WRAPPER" "$CONTROLLER" "$SERVER"; do
  [ -x "$file" ] || {
    printf 'recovery-lock helper is not executable: %s\n' "$file" >&2
    exit 1
  }
done
bash -n "$WRAPPER"
bash -n "$CONTROLLER"
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$SERVER" >/dev/null
fi

grep -q 'ROUTER_UI_MAC_PRO_HOST:-mac-pro-hosting' "$WRAPPER"
grep -q 'MODE=focused' "$WRAPPER"
grep -q 'LOCK_GRACE_SECONDS=15' "$CONTROLLER"
grep -q 'memory" = 256' "$CONTROLLER"
grep -q 'memory <= 300' "$CONTROLLER"
grep -q 'STOCK_WRITABLE_BACKING_KIB=54436' "$CONTROLLER"
grep -q 'STOCK_EXPECTED_DF_KIB=51352' "$CONTROLLER"
grep -q 'snapshot.*restore' "$CONTROLLER"
grep -q 'terminal state coexists with owned live lock' "$CONTROLLER"
grep -q 'kill "$SERVER_PID"' "$CONTROLLER"
grep -q 'wait "$SERVER_PID"' "$CONTROLLER"

! grep -Eq 'gh workflow|gh run (rerun|cancel)|workflow_dispatch|qemu-system|pkill|killall' \
  "$WRAPPER" "$CONTROLLER"
! git -C "$ROOT_DIR" diff --name-only | grep -q '^\.github/workflows/'

printf 'Mac Pro VirtualBox recovery-lock reproducer contract passed\n'
