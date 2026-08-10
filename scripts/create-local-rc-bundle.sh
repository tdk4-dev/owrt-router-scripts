#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_COMMIT="${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
CANDIDATE_DIR="${CANDIDATE_DIR:?CANDIDATE_DIR is required}"
REPORT_DIR="${REPORT_DIR:?REPORT_DIR is required}"
OUTPUT_ROOT="${OUTPUT_ROOT:?OUTPUT_ROOT is required}"
USIGN_BIN="${USIGN_BIN:?USIGN_BIN is required}"
EXPECTED_KEY_ID="${ROUTER_UI_SIGNING_KEY_ID:?ROUTER_UI_SIGNING_KEY_ID is required}"
RC_NUMBER="${RC_NUMBER:?RC_NUMBER is required}"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
SHORT_SHA="${SOURCE_COMMIT:0:8}"
UTC_TIMESTAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
[[ "$RC_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  printf 'RC-BUNDLE-ERROR: RC_NUMBER must be a positive integer\n' >&2
  exit 1
}
[[ "$APP_VERSION" = "0.7.11-rc.$RC_NUMBER" ]] || {
  printf 'RC-BUNDLE-ERROR: VERSION %s does not match RC_NUMBER %s\n' \
    "$APP_VERSION" "$RC_NUMBER" >&2
  exit 1
}
NAME="Premier-Router-$APP_VERSION-$SHORT_SHA-$UTC_TIMESTAMP"
RC_DIR="$OUTPUT_ROOT/$NAME"
ARCHIVE="$OUTPUT_ROOT/$NAME.tar.gz"
VERIFY_ROOT="$(mktemp -d "$OUTPUT_ROOT/.verify-$NAME.XXXXXX")"

fail() { printf 'RC-BUNDLE-ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$VERIFY_ROOT"; }
trap cleanup EXIT INT TERM

[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$SOURCE_COMMIT" ]]
[[ -z "$(git -C "$ROOT_DIR" status --short)" ]]
[[ -d "$CANDIDATE_DIR" && -d "$REPORT_DIR" && -d "$OUTPUT_ROOT" ]]
[[ ! -e "$RC_DIR" && ! -e "$ARCHIVE" ]] || fail 'immutable RC target already exists'

mkdir -p "$RC_DIR/release" "$RC_DIR/reports"
cp -R "$CANDIDATE_DIR/." "$RC_DIR/release/"
for report in validation-report.md VM-EVIDENCE-INDEX.md PUBLICATION-CHECKLIST.md \
  ordinary-user-ipk-installation.md issue-10-status.md; do
  [[ -s "$REPORT_DIR/$report" ]] || fail "missing compact RC report: $report"
  cp "$REPORT_DIR/$report" "$RC_DIR/reports/$report"
done
printf '%s\n' "$EXPECTED_KEY_ID" > "$RC_DIR/reports/production-key-id"
cp "$ROOT_DIR/release/keys/$EXPECTED_KEY_ID.fingerprint" "$RC_DIR/reports/production-key-fingerprint"

RELEASE_DIR="$RC_DIR/release" RELEASE_CHANNEL=candidate REQUIRE_IMAGES=1 STRICT_RELEASE=1 \
  REQUIRE_MAIN_ANCESTRY=0 EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  EXPECTED_RELEASE_KEY_ID="$EXPECTED_KEY_ID" USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/validate-staged-release.sh" > "$VERIFY_ROOT/archive-preflight.raw.log"
printf 'result=passed\nsource_commit=%s\nsigning_key_id=%s\n' \
  "$SOURCE_COMMIT" "$EXPECTED_KEY_ID" > "$RC_DIR/reports/archive-preflight.log"

if find "$RC_DIR" -type f \( -name '*.sec' -o -name '*.key' -o -name '*.pem' \
  -o -name '.env' -o -name 'id_rsa*' -o -name 'id_ed25519*' \) | grep -q .; then
  fail 'RC contains a secret-key-shaped filename'
fi
if grep -RIlE 'BEGIN (OPENSSH |RSA |EC )?PRIVATE KEY|ROUTER_UI_SIGNING_KEY=/|/Users/|/private/tmp/|/home/[^/]+/' \
  "$RC_DIR" | grep -q .; then
  fail 'RC contains secret material or an absolute private path'
fi
! grep -RIl '0.7.12-test1' "$RC_DIR" | grep -q . || fail 'disposable next candidate entered the 0.7.11 RC'

COPYFILE_DISABLE=1 tar --format ustar --no-xattrs --no-mac-metadata \
  --owner=0 --group=0 --numeric-owner -czf "$ARCHIVE" -C "$OUTPUT_ROOT" "$NAME"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
tar -tzf "$ARCHIVE" > "$OUTPUT_ROOT/$NAME.file-list.txt"
tar -xzf "$ARCHIVE" -C "$VERIFY_ROOT"
EXTRACTED="$VERIFY_ROOT/$NAME"
[[ -d "$EXTRACTED/release" && -d "$EXTRACTED/reports" ]]
RELEASE_DIR="$EXTRACTED/release" RELEASE_CHANNEL=candidate REQUIRE_IMAGES=1 STRICT_RELEASE=1 \
  REQUIRE_MAIN_ANCESTRY=0 EXPECTED_SOURCE_COMMIT="$SOURCE_COMMIT" \
  EXPECTED_RELEASE_KEY_ID="$EXPECTED_KEY_ID" USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/validate-staged-release.sh" > "$VERIFY_ROOT/archive-extraction-validation.log"
diff -ru "$RC_DIR" "$EXTRACTED" >/dev/null || fail 'archive extraction differs from immutable RC directory'

rm -rf "$VERIFY_ROOT"
trap - EXIT INT TERM
chmod -R a-w "$RC_DIR"
chmod 0444 "$ARCHIVE" "$ARCHIVE.sha256" "$OUTPUT_ROOT/$NAME.file-list.txt"
printf 'rc_directory=%s\nrc_archive=%s\nrc_archive_sha256=%s\n' \
  "$RC_DIR" "$ARCHIVE" "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
