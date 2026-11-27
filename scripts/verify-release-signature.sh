#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ROUTER_UI_RELEASE_ROOT="${ROUTER_UI_RELEASE_ROOT:-$ROOT_DIR}"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

[ "$#" = 3 ] || {
  printf 'usage: %s KEY_ID MESSAGE SIGNATURE\n' "$0" >&2
  exit 2
}
key_id="$1"
message="$2"
signature="$3"
[ -f "$message" ] || { printf 'ERROR: message is missing\n' >&2; exit 1; }
[ -f "$signature" ] || { printf 'ERROR: signature is missing\n' >&2; exit 1; }
pr_select_trusted_key "$key_id" 'active previous' || exit 1
"$USIGN_BIN" -q -V -p "$RELEASE_PUBLIC_KEY" -m "$message" -x "$signature" || {
  printf 'ERROR: signature verification failed for key %s\n' "$key_id" >&2
  exit 1
}
printf 'verified signature with key %s (%s, %s)\n' \
  "$RELEASE_KEY_ID" "$RELEASE_KEY_FINGERPRINT" "$RELEASE_KEY_STATUS"
