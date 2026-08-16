#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'signing:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
USIGN_BIN="${TEST_USIGN_BIN:-$(command -v usign || true)}"
[ -x "$USIGN_BIN" ] || {
  printf 'usign is required for local signing lifecycle tests\n' >&2
  exit 1
}
for tool in awk find jq sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'missing signing lifecycle test dependency: %s\n' "$tool" >&2
    exit 1
  }
done

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-signing-test.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT HUP INT TERM

fail() { printf 'signing lifecycle test failed: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  expected="$1"
  log="$2"
  shift 2
  if "$@" >"$log" 2>&1; then
    fail "command unexpectedly succeeded: $expected"
  fi
  grep -Fq "$expected" "$log" || fail "expected refusal was not logged: $expected"
}
generate_key() {
  name="$1"
  "$USIGN_BIN" -G -s "$TMP_ROOT/$name.sec" -p "$TMP_ROOT/$name.pub" \
    -c "Premier Router disposable test key $name"
  chmod 0600 "$TMP_ROOT/$name.sec"
  "$USIGN_BIN" -F -p "$TMP_ROOT/$name.pub" > "$TMP_ROOT/$name.fingerprint"
}

# Repository trust material must contain no private-key-shaped file.
if find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type f \
  \( -name '*.sec' -o -name '*.priv' -o -name '*.private' \
     -o -iname '*private*key*' -o -iname '*secret*key*' \) -print | grep -q .; then
  fail "repository contains a private-key-shaped file"
fi
[ "$("$USIGN_BIN" -F -p "$ROOT_DIR/release/keys/production-2026-07.pub")" = \
  "$(sed -n '1p' "$ROOT_DIR/release/keys/production-2026-07.fingerprint")" ] ||
  fail "active committed public key and fingerprint differ"

for key in active previous revoked wrong; do generate_key "$key"; done
FIXTURE_ROOT="$TMP_ROOT/fixture-root"
FIXTURE_KEYS="$FIXTURE_ROOT/keys/release"
mkdir -p "$FIXTURE_KEYS"
for key in active previous revoked; do cp "$TMP_ROOT/$key.pub" "$FIXTURE_KEYS/$key.pub"; done
active_fp="$(sed -n '1p' "$TMP_ROOT/active.fingerprint")"
previous_fp="$(sed -n '1p' "$TMP_ROOT/previous.fingerprint")"
revoked_fp="$(sed -n '1p' "$TMP_ROOT/revoked.fingerprint")"
jq -n --arg active_fp "$active_fp" --arg previous_fp "$previous_fp" \
  --arg revoked_fp "$revoked_fp" '
  {
    schema_version:1,
    active_key_id:"test-active",
    keys:[
      {key_id:"test-active",fingerprint:$active_fp,status:"active",
       creation_date:"2026-07-21",public_key_path:"keys/release/active.pub"},
      {key_id:"test-previous",fingerprint:$previous_fp,status:"previous",
       creation_date:"2026-07-20",retirement_date:"2026-07-21",
       public_key_path:"keys/release/previous.pub"},
      {key_id:"test-revoked",fingerprint:$revoked_fp,status:"revoked",
       creation_date:"2026-07-19",retirement_date:"2026-07-20",
       public_key_path:"keys/release/revoked.pub"}
    ]
  }' > "$FIXTURE_KEYS/trusted-keys.json"

MESSAGE="$TMP_ROOT/release-manifest.fixture"
printf '%s\n' 'small disposable signing fixture' > "$MESSAGE"
SIGNED_DIR="$TMP_ROOT/signed-active"
PROVENANCE="$TMP_ROOT/signing-provenance.json"
COMMON_ENV="ROUTER_UI_RELEASE_ROOT=$FIXTURE_ROOT ROUTER_UI_TRUSTED_KEYS_FILE=$FIXTURE_KEYS/trusted-keys.json USIGN_BIN=$USIGN_BIN"

expect_failure 'private signing key fingerprint does not match' "$TMP_ROOT/wrong.log" \
  env $COMMON_ENV ROUTER_UI_SIGNING_KEY_ID=test-active \
  ROUTER_UI_SIGNING_KEY="$TMP_ROOT/wrong.sec" \
  "$ROOT_DIR/scripts/sign-release-inputs.sh" --output-dir "$TMP_ROOT/wrong-out" "$MESSAGE"

chmod 0644 "$TMP_ROOT/active.sec"
expect_failure 'must have mode 0600' "$TMP_ROOT/permissions.log" \
  env $COMMON_ENV ROUTER_UI_SIGNING_KEY_ID=test-active \
  ROUTER_UI_SIGNING_KEY="$TMP_ROOT/active.sec" \
  "$ROOT_DIR/scripts/sign-release-inputs.sh" --output-dir "$TMP_ROOT/insecure-out" "$MESSAGE"
chmod 0600 "$TMP_ROOT/active.sec"

env $COMMON_ENV ROUTER_UI_SIGNING_KEY_ID=test-active \
  ROUTER_UI_SIGNING_KEY="$TMP_ROOT/active.sec" \
  "$ROOT_DIR/scripts/sign-release-inputs.sh" --output-dir "$SIGNED_DIR" \
  --provenance "$PROVENANCE" "$MESSAGE" > "$TMP_ROOT/active-sign.log" 2>&1
env $COMMON_ENV "$ROOT_DIR/scripts/verify-release-signature.sh" test-active \
  "$MESSAGE" "$SIGNED_DIR/$(basename "$MESSAGE").sig" > "$TMP_ROOT/active-verify.log" 2>&1

"$USIGN_BIN" -S -m "$MESSAGE" -s "$TMP_ROOT/previous.sec" -x "$TMP_ROOT/previous.sig"
env $COMMON_ENV "$ROOT_DIR/scripts/verify-release-signature.sh" test-previous \
  "$MESSAGE" "$TMP_ROOT/previous.sig" > "$TMP_ROOT/previous-verify.log" 2>&1
"$USIGN_BIN" -S -m "$MESSAGE" -s "$TMP_ROOT/revoked.sec" -x "$TMP_ROOT/revoked.sig"
expect_failure 'has disallowed status: revoked' "$TMP_ROOT/revoked.log" \
  env $COMMON_ENV "$ROOT_DIR/scripts/verify-release-signature.sh" test-revoked \
  "$MESSAGE" "$TMP_ROOT/revoked.sig"
"$USIGN_BIN" -S -m "$MESSAGE" -s "$TMP_ROOT/wrong.sec" -x "$TMP_ROOT/unknown.sig"
expect_failure 'unknown release signing key ID' "$TMP_ROOT/unknown.log" \
  env $COMMON_ENV "$ROOT_DIR/scripts/verify-release-signature.sh" test-unknown \
  "$MESSAGE" "$TMP_ROOT/unknown.sig"

# The on-router resolver uses the packaged registry form and the same status policy.
RUNTIME_REGISTRY="$TMP_ROOT/runtime-trusted-keys.json"
jq '.keys |= map(.public_key_path = (.public_key_path | split("/") | last))' \
  "$FIXTURE_KEYS/trusted-keys.json" > "$RUNTIME_REGISTRY"
for accepted in test-active test-previous; do
  PREMIER_ROUTER_HOST_TEST=1 PR_USIGN_BIN="$USIGN_BIN" sh -c \
    '. "$1"; pr_resolve_trusted_release_key "$2" "$3" "$4"' sh \
    "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
    "$RUNTIME_REGISTRY" "$FIXTURE_KEYS" "$accepted" ||
    fail "on-router resolver rejected $accepted"
done
expect_failure 'release key is not trusted' "$TMP_ROOT/runtime-revoked.log" \
  env PREMIER_ROUTER_HOST_TEST=1 PR_USIGN_BIN="$USIGN_BIN" sh -c \
  '. "$1"; pr_resolve_trusted_release_key "$2" "$3" "$4"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  "$RUNTIME_REGISTRY" "$FIXTURE_KEYS" test-revoked
expect_failure 'unknown release key ID' "$TMP_ROOT/runtime-unknown.log" \
  env PREMIER_ROUTER_HOST_TEST=1 PR_USIGN_BIN="$USIGN_BIN" sh -c \
  '. "$1"; pr_resolve_trusted_release_key "$2" "$3" "$4"' sh \
  "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  "$RUNTIME_REGISTRY" "$FIXTURE_KEYS" test-unknown

jq -e --arg id test-active --arg fp "$active_fp" '
  .schema_version == 1 and .signing_key_id == $id and
  .signing_key_fingerprint == $fp and (.inputs | length == 1) and
  (tostring | contains(".sec") | not) and
  (tostring | contains("ROUTER_UI_SIGNING_KEY") | not)
' "$PROVENANCE" >/dev/null || fail "signing provenance leaked a private path or omitted public identity"

RAM_ROOT="$TMP_ROOT/ram"
EPHEMERAL_DIR="$TMP_ROOT/signed-ephemeral"
mkdir -p "$RAM_ROOT"
env $COMMON_ENV ROUTER_UI_SIGNING_KEY_ID=test-active ROUTER_UI_EPHEMERAL_TEST=1 \
  ROUTER_UI_VM_RAM_ROOT="$RAM_ROOT" \
  "$ROOT_DIR/scripts/sign-in-linux-build-vm.sh" --output-dir "$EPHEMERAL_DIR" \
  "$MESSAGE" < "$TMP_ROOT/active.sec" > "$TMP_ROOT/ephemeral.log" 2>&1
find "$RAM_ROOT" -mindepth 1 -print | grep -q . && fail "ephemeral helper left its key path behind"
env $COMMON_ENV "$ROOT_DIR/scripts/verify-release-signature.sh" test-active \
  "$MESSAGE" "$EPHEMERAL_DIR/$(basename "$MESSAGE").sig" >/dev/null

# Secret key payload lines must not occur in logs, provenance, or signed outputs.
for secret in "$TMP_ROOT/active.sec" "$TMP_ROOT/previous.sec" \
  "$TMP_ROOT/revoked.sec" "$TMP_ROOT/wrong.sec"; do
  for artifact in "$TMP_ROOT"/*.log "$PROVENANCE" "$SIGNED_DIR"/* "$EPHEMERAL_DIR"/*; do
    [ -f "$artifact" ] || continue
    awk 'NR == FNR { if (FNR == 2) secret = $0; next }
      secret != "" && index($0, secret) { found = 1 }
      END { exit found }' "$secret" "$artifact" ||
      fail "disposable secret bytes appeared in logs or staged fixtures"
  done
done

printf 'Local signing key lifecycle tests passed\n'
