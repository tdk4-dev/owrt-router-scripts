#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'signing:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ROUTER_UI_RELEASE_ROOT="${ROUTER_UI_RELEASE_ROOT:-$ROOT_DIR}"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'usage: %s --output-dir DIR [--provenance FILE] INPUT...\n' "$0" >&2
  exit 2
}

output_dir=
provenance=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir) [ "$#" -ge 2 ] || usage; output_dir="$2"; shift 2 ;;
    --provenance) [ "$#" -ge 2 ] || usage; provenance="$2"; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ -n "$output_dir" ] && [ "$#" -gt 0 ] || usage
case "$output_dir" in /*) ;; *) fail "output directory must be absolute" ;; esac
[ -z "$provenance" ] || case "$provenance" in /*) ;; *) fail "provenance path must be absolute" ;; esac
pr_require_active_signing_key || exit 1
command -v jq >/dev/null 2>&1 || fail "missing required command: jq"
command -v sha256sum >/dev/null 2>&1 || fail "missing required command: sha256sum"
mkdir -p "$output_dir"
inputs_json='[]'
seen_names=' '
for input in "$@"; do
  [ -f "$input" ] || fail "signing input is not a regular file: $input"
  name="$(basename "$input")"
  case " $seen_names " in *" $name "*) fail "duplicate signing input basename: $name" ;; esac
  seen_names="$seen_names$name "
  signature="$output_dir/$name.sig"
  [ ! -e "$signature" ] || fail "signature target already exists: $signature"
  "$USIGN_BIN" -S -m "$input" -s "$SIGNING_KEY" -x "$signature"
  object="$(jq -n --arg filename "$name" \
    --arg sha256 "$(sha256sum "$input" | awk '{print $1}')" \
    --arg signature_filename "$name.sig" \
    '{filename:$filename,sha256:$sha256,signature_filename:$signature_filename}')"
  inputs_json="$(printf '%s' "$inputs_json" | jq --argjson object "$object" '. + [$object]')"
done
if [ -n "$provenance" ]; then
  [ ! -e "$provenance" ] || fail "provenance target already exists: $provenance"
  jq -n --arg key_id "$RELEASE_KEY_ID" --arg fingerprint "$RELEASE_KEY_FINGERPRINT" \
    --argjson inputs "$inputs_json" \
    '{schema_version:1,signing_key_id:$key_id,
      signing_key_fingerprint:$fingerprint,inputs:$inputs}' |
    jq -S . > "$provenance"
fi
printf 'signed %s input(s) with key %s (%s)\n' "$#" "$RELEASE_KEY_ID" "$RELEASE_KEY_FINGERPRINT"
