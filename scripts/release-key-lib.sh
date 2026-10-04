#!/bin/sh

# Shared local release-key policy. This file is sourced by release tooling.

if [ -z "${ROUTER_UI_RELEASE_ROOT:-}" ]; then
  ROUTER_UI_RELEASE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fi
ROUTER_UI_TRUSTED_KEYS_FILE="${ROUTER_UI_TRUSTED_KEYS_FILE:-$ROUTER_UI_RELEASE_ROOT/release/keys/trusted-keys.json}"
ROUTER_UI_TRUST_ROOT="${ROUTER_UI_TRUST_ROOT:-$ROUTER_UI_RELEASE_ROOT}"
USIGN_BIN="${USIGN_BIN:-usign}"

pr_key_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

pr_require_tool() {
  command -v "$1" >/dev/null 2>&1 || pr_key_fail "missing required command: $1"
}

pr_validate_registry() {
  pr_require_tool jq || return 1
  [ -f "$ROUTER_UI_TRUSTED_KEYS_FILE" ] ||
    pr_key_fail "trusted-key registry is missing: $ROUTER_UI_TRUSTED_KEYS_FILE" || return 1
  jq -e '
    .schema_version == 1 and
    (.active_key_id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.keys | type == "array" and length > 0) and
    ([.keys[].key_id] | length == (unique | length)) and
    ([.keys[].fingerprint] | length == (unique | length)) and
    ([.keys[].public_key_path | split("/") | last] | length == (unique | length)) and
    ([.keys[] | select(
      (.key_id | type != "string" or (test("^[A-Za-z0-9._-]+$") | not)) or
      (.fingerprint | type != "string" or (test("^[0-9a-f]{16}$") | not)) or
      (.status != "active" and .status != "previous" and .status != "revoked") or
      (.creation_date | type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)) or
      (.public_key_path | type != "string" or startswith("/") or
        test("(^|/)\\.\\.(/|$)")) or
      (has("retirement_date") and
        (.retirement_date | type != "string" or
          (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)))
    )] | length == 0) and
    ([.keys[] | select(.status == "active")] | length == 1) and
    ([.keys[] | select(.status == "previous")] | length <= 1) and
    ([.keys[] | select(.status == "active") | .key_id] == [.active_key_id]) and
    ([.keys[] | select(.status == "revoked" and (has("retirement_date") | not))] |
      length == 0)
  ' "$ROUTER_UI_TRUSTED_KEYS_FILE" >/dev/null ||
    pr_key_fail "trusted-key registry is invalid" || return 1
}

pr_select_trusted_key() {
  key_id="$1"
  allowed_statuses="$2"
  pr_validate_registry || return 1
  pr_require_tool "$USIGN_BIN" || return 1
  entry_count="$(jq -r --arg key_id "$key_id" \
    '[.keys[] | select(.key_id == $key_id)] | length' "$ROUTER_UI_TRUSTED_KEYS_FILE")"
  [ "$entry_count" = 1 ] || pr_key_fail "unknown release signing key ID: $key_id" || return 1
  RELEASE_KEY_STATUS="$(jq -r --arg key_id "$key_id" \
    '.keys[] | select(.key_id == $key_id) | .status' "$ROUTER_UI_TRUSTED_KEYS_FILE")"
  case " $allowed_statuses " in
    *" $RELEASE_KEY_STATUS "*) ;;
    *) pr_key_fail "release signing key $key_id has disallowed status: $RELEASE_KEY_STATUS"; return 1 ;;
  esac
  release_public_relative="$(jq -r --arg key_id "$key_id" \
    '.keys[] | select(.key_id == $key_id) | .public_key_path' "$ROUTER_UI_TRUSTED_KEYS_FILE")"
  RELEASE_PUBLIC_KEY="$ROUTER_UI_TRUST_ROOT/$release_public_relative"
  [ -f "$RELEASE_PUBLIC_KEY" ] ||
    pr_key_fail "trusted public key is missing: $release_public_relative" || return 1
  RELEASE_KEY_FINGERPRINT="$(jq -r --arg key_id "$key_id" \
    '.keys[] | select(.key_id == $key_id) | .fingerprint' "$ROUTER_UI_TRUSTED_KEYS_FILE")"
  actual_public_fingerprint="$("$USIGN_BIN" -F -p "$RELEASE_PUBLIC_KEY")" ||
    pr_key_fail "could not derive trusted public-key fingerprint" || return 1
  [ "$actual_public_fingerprint" = "$RELEASE_KEY_FINGERPRINT" ] ||
    pr_key_fail "trusted public key fingerprint does not match registry for $key_id" || return 1
  RELEASE_KEY_ID="$key_id"
  export RELEASE_KEY_ID RELEASE_KEY_STATUS RELEASE_KEY_FINGERPRINT RELEASE_PUBLIC_KEY
}

pr_select_active_public_key() {
  selected_key_id="${ROUTER_UI_SIGNING_KEY_ID:-}"
  [ -n "$selected_key_id" ] ||
    pr_key_fail "ROUTER_UI_SIGNING_KEY_ID is required" || return 1
  registry_active_id="$(jq -r '.active_key_id' "$ROUTER_UI_TRUSTED_KEYS_FILE" 2>/dev/null || true)"
  [ "$selected_key_id" = "$registry_active_id" ] ||
    pr_key_fail "new signing requires the registry active key ID" || return 1
  pr_select_trusted_key "$selected_key_id" active
}

pr_private_key_mode() {
  private_key_path="$1"
  if stat -c '%a' "$private_key_path" >/dev/null 2>&1; then
    stat -c '%a' "$private_key_path"
  else
    stat -f '%Lp' "$private_key_path"
  fi
}

pr_require_active_signing_key() {
  private_key_path="${ROUTER_UI_SIGNING_KEY:-}"
  [ -n "$private_key_path" ] ||
    pr_key_fail "ROUTER_UI_SIGNING_KEY is required" || return 1
  case "$private_key_path" in
    /*) ;;
    *) pr_key_fail "ROUTER_UI_SIGNING_KEY must be an absolute path"; return 1 ;;
  esac
  [ -f "$private_key_path" ] && [ ! -L "$private_key_path" ] ||
    pr_key_fail "ROUTER_UI_SIGNING_KEY must name an existing regular file" || return 1
  private_key_mode="$(pr_private_key_mode "$private_key_path")" ||
    pr_key_fail "could not inspect private-key permissions" || return 1
  [ "$private_key_mode" = 600 ] ||
    pr_key_fail "ROUTER_UI_SIGNING_KEY must have mode 0600 (found $private_key_mode)" || return 1
  case "$USIGN_BIN" in
    /*) ;;
    *) pr_key_fail "USIGN_BIN must be an absolute path for signing"; return 1 ;;
  esac
  [ -x "$USIGN_BIN" ] || pr_key_fail "USIGN_BIN is not executable: $USIGN_BIN" || return 1
  pr_select_active_public_key || return 1
  private_fingerprint="$("$USIGN_BIN" -F -s "$private_key_path")" ||
    pr_key_fail "could not derive private-key fingerprint" || return 1
  [ "$private_fingerprint" = "$RELEASE_KEY_FINGERPRINT" ] ||
    pr_key_fail "private signing key fingerprint does not match trusted key $RELEASE_KEY_ID" || return 1
  SIGNING_KEY="$private_key_path"
  export SIGNING_KEY
}

pr_require_committed_registry() {
  committed_registry="$ROUTER_UI_RELEASE_ROOT/release/keys/trusted-keys.json"
  [ "$ROUTER_UI_TRUSTED_KEYS_FILE" = "$committed_registry" ] &&
    [ "$ROUTER_UI_TRUST_ROOT" = "$ROUTER_UI_RELEASE_ROOT" ] ||
    pr_key_fail "strict release requires the committed trusted-key registry"
}
