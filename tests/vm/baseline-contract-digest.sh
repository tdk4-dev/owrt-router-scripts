#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/tests/vm/fixtures/legacy-nonsecret"

emit() {
  path="$1"
  [ -f "$ROOT_DIR/$path" ] || {
    printf 'Missing baseline-contract input: %s\n' "$path" >&2
    exit 1
  }
  printf '%s  %s\n' "$(sha256sum "$ROOT_DIR/$path" | awk '{print $1}')" "$path"
}

{
  emit tests/vm/legacy-baseline-lock.json
  emit tests/vm/router-ui-vm-gate.sh
  emit tests/vm/router-ui-vm-guest.sh
  emit tests/vm/fail-closed-runner.sh
  emit tests/vm/recovery-readiness.sh
  emit image/openwrt-fin0-packages.txt
  emit release/rd23-storage-geometry.json
  emit scripts/patch-openwrt-x86-writable-extent.sh
  find "$FIXTURE_DIR" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    relative="${file#"$ROOT_DIR/"}"
    emit "$relative"
  done
} | sha256sum | awk '{print $1}'
