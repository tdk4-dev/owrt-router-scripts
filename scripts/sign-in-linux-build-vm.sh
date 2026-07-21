#!/bin/sh
set -eu
umask 077

# Run this script inside the Linux build VM. Private usign bytes arrive only on
# stdin; input file paths are non-secret and may be passed as arguments.
set +x
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RAM_ROOT="${ROUTER_UI_VM_RAM_ROOT:-/dev/shm}"
if [ "$RAM_ROOT" != /dev/shm ] && [ "${ROUTER_UI_EPHEMERAL_TEST:-0}" != 1 ]; then
  printf 'ERROR: production ephemeral signing requires /dev/shm\n' >&2
  exit 1
fi
[ -d "$RAM_ROOT" ] || { printf 'ERROR: RAM-backed signing root is unavailable: %s\n' "$RAM_ROOT" >&2; exit 1; }

signing_dir="$(mktemp -d "$RAM_ROOT/router-ui-signing.XXXXXX")"
key_file="$signing_dir/signing-key.sec"
cleanup() {
  set +x
  rm -f "$key_file"
  rmdir "$signing_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

dd of="$key_file" bs=4096 2>/dev/null
chmod 0600 "$key_file"
[ -s "$key_file" ] || { printf 'ERROR: no private key received on stdin\n' >&2; exit 1; }
ROUTER_UI_SIGNING_KEY="$key_file"
export ROUTER_UI_SIGNING_KEY
if [ "${1:-}" = --release-tool ]; then
  [ "$#" -ge 2 ] || { printf 'ERROR: --release-tool requires a tool name\n' >&2; exit 2; }
  release_tool="$2"
  shift 2
  case "$release_tool" in
    stage-installed-package-set.sh|stage-router-release.sh) ;;
    *) printf 'ERROR: release tool is not allowed: %s\n' "$release_tool" >&2; exit 2 ;;
  esac
  "$ROOT_DIR/scripts/$release_tool" "$@"
else
  "$ROOT_DIR/scripts/sign-release-inputs.sh" "$@"
fi
cleanup
trap - EXIT HUP INT TERM
[ ! -e "$key_file" ] && [ ! -e "$signing_dir" ] || {
  printf 'ERROR: ephemeral signing key cleanup failed\n' >&2
  exit 1
}
printf 'ephemeral signing key removed\n'
