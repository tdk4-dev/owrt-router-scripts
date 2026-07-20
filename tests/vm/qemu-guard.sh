#!/bin/bash
set -euo pipefail

LOCK_ROOT="${ROUTER_UI_VM_LOCK_ROOT:-/tmp/router-ui-vm-semaphore}"
mkdir -p "$LOCK_ROOT"
running="$(pgrep -fc 'qemu-system-.*-name router-ui-vm-' 2>/dev/null || true)"
running="${running:-0}"
if (( running >= 2 )); then
  printf 'Refusing to start a third Router UI project VM (%s already running)\n' "$running" >&2
  exit 73
fi

exec 8>"$LOCK_ROOT/slot-1.lock"
if flock -n 8; then exec "$@"; fi
exec 9>"$LOCK_ROOT/slot-2.lock"
if flock -n 9; then exec "$@"; fi

printf 'Refusing to start a third Router UI project VM (both semaphore slots are owned)\n' >&2
exit 73
