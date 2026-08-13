#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-rescue-matrix.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
printf "DISTRIB_RELEASE='24.10.5'\nDISTRIB_TARGET='x86/64'\n" > "$TMP_ROOT/openwrt_release"

run_source() {
  version="$1"
  printf '%s\n' "$version" > "$TMP_ROOT/version"
  PREMIER_ROUTER_HOST_TEST=1 ROUTER_UI_TEST_VALIDATE_SOURCE_ONLY=1 \
    ROUTER_UI_VERSION_FILE="$TMP_ROOT/version" \
    ROUTER_UI_OPENWRT_RELEASE_FILE="$TMP_ROOT/openwrt_release" \
    sh "$ROOT_DIR/rescue-router-ui.sh"
}

for version in 0.7.0 0.7.1 0.7.2 0.7.3 0.7.4 0.7.5 0.7.6 0.7.8 0.7.9 0.7.10; do
  run_source "$version" | grep -Fqx "Recognized rescue source: $version"
done
for version in 0.5.1 0.5.2 0.6.0 0.7.7 0.7.12 0.8.0RC2 development dirty ''; do
  if run_source "$version" > "$TMP_ROOT/rejected.out" 2> "$TMP_ROOT/rejected.err"; then
    printf 'rescue accepted unsupported source: %s\n' "${version:-empty}" >&2
    exit 1
  fi
done
grep -q 'tag-only' "$TMP_ROOT/rejected.err" || true

grep -q 'TARGET_VERSION=0.7.11' "$ROOT_DIR/rescue-router-ui.sh"
grep -q 'TARGET_TAG="vpn-panel-v\$TARGET_VERSION"' "$ROOT_DIR/rescue-router-ui.sh"
! grep -Eq 'releases/latest|opkg upgrade|sysupgrade ' "$ROOT_DIR/rescue-router-ui.sh"
grep -Fq 'embedded release public-key fingerprint mismatch' "$ROOT_DIR/rescue-router-ui.sh"
grep -Fq 'case "$TARGET_CHANNEL" in stable|candidate)' "$ROOT_DIR/rescue-router-ui.sh"
grep -Fq 'ROUTER_UI_RELEASE_CHANNEL="$TARGET_CHANNEL"' "$ROOT_DIR/rescue-router-ui.sh"

PREMIER_ROUTER_HOST_TEST=1 ROUTER_UI_TEST_VALIDATE_REQUESTED_VERSION_ONLY=1 \
  ROUTER_UI_VERSION=0.7.11-rc.9 sh "$ROOT_DIR/install-router-ui-release.sh" |
  grep -Fqx 'Recognized requested version: 0.7.11-rc.9'
if PREMIER_ROUTER_HOST_TEST=1 ROUTER_UI_TEST_VALIDATE_REQUESTED_VERSION_ONLY=1 \
  ROUTER_UI_VERSION=0.7.11-rc sh "$ROOT_DIR/install-router-ui-release.sh" \
  > "$TMP_ROOT/installer-rejected.out" 2> "$TMP_ROOT/installer-rejected.err"; then
  printf 'installer accepted malformed dotted RC version\n' >&2
  exit 1
fi
grep -Fq 'requested version is malformed' "$TMP_ROOT/installer-rejected.err"

printf 'Explicit generic-rescue support and refusal matrix passed\n'
