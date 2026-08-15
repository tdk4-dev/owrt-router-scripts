#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-tier0-guards.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

ENTRYPOINTS='
build-openwrt-custom-image-linux.sh
build-openwrt-x86-fin0-image-linux.sh
make-vpn-ui-release-bundle.sh
publish-vpn-panel-release.sh
scripts/build-openwrt-ipks.sh
scripts/create-local-rc-bundle.sh
scripts/install-ci-ucode.sh
scripts/install-ci-usign.sh
scripts/render-router-ui-install-guide.py
scripts/sign-in-linux-build-vm.sh
scripts/sign-opkg-feed.sh
scripts/sign-release-inputs.sh
scripts/stage-factory-schema2-contract.sh
scripts/stage-installed-package-set.sh
scripts/stage-router-release.sh
scripts/validate-staged-release.sh
tests/test-factory-schema2-staging.sh
tests/test-local-signing-key-lifecycle.sh
tests/test-release-publisher.sh
tests/test-router-ui-release-v2.sh
tests/integration/repro-recovery-lock-mac-pro.sh
tests/integration/run-router-ui-virtualbox-matrix-mac-pro.sh
tests/integration/run-vanilla-ipk-install-mac-pro.sh
tests/vm/build-synthetic-next.sh
tests/vm/router-ui-vm-gate.sh
'

printf '%s\n' "$ENTRYPOINTS" | while IFS= read -r relative; do
  [ -n "$relative" ] || continue
  entrypoint="$ROOT_DIR/$relative"
  [ -f "$entrypoint" ] || {
    printf 'missing guarded Tier 0 entrypoint: %s\n' "$relative" >&2
    exit 1
  }
  probe="$TMP_ROOT/$(printf '%s' "$relative" | tr '/' '_').log"
  first="$(sed -n '1p' "$entrypoint")"
  set +e
  case "$relative:$first" in
    scripts/render-router-ui-install-guide.py:*)
      output="$TMP_ROOT/guarded-renderer-output.pdf"
      ROUTER_UI_TIER0_GUARD_LOG="$probe" python3 "$entrypoint" \
        --manifest "$ROOT_DIR/tests/fixtures/release/router-ui-0.7.11-rc11-provisional-manifest.json" \
        --rules "$ROOT_DIR/release/router-ui-release-rules.json" \
        --template "$ROOT_DIR/docs/templates/router-ui-install-guide-template.json" \
        --mode fixture --output "$output" >/dev/null 2>&1 ;;
    *:*python*) ROUTER_UI_TIER0_GUARD_LOG="$probe" python3 "$entrypoint" >/dev/null 2>&1 ;;
    *bash*) ROUTER_UI_TIER0_GUARD_LOG="$probe" bash "$entrypoint" >/dev/null 2>&1 ;;
    *) ROUTER_UI_TIER0_GUARD_LOG="$probe" sh "$entrypoint" >/dev/null 2>&1 ;;
  esac
  code=$?
  set -e
  [ "$code" -eq 97 ] || {
    printf 'Tier 0 entrypoint did not stop with exit 97: %s (exit %s)\n' "$relative" "$code" >&2
    exit 1
  }
  [ "$(awk 'NF {count++} END {print count+0}' "$probe")" -eq 1 ] || {
    printf 'Tier 0 entrypoint did not emit exactly one guard record: %s\n' "$relative" >&2
    exit 1
  }
  grep -F ":${relative##*/}" "$probe" >/dev/null || {
    printf 'Tier 0 guard record did not identify its entrypoint: %s\n' "$relative" >&2
    exit 1
  }
  [ ! -e "${output:-$TMP_ROOT/no-output-for-this-entrypoint}" ] || {
    printf 'Tier 0 entrypoint created guarded output: %s\n' "$relative" >&2
    exit 1
  }
  unset output
done

printf '%s\n' 'Tier 0 guarded product, compiler-adjacent, signing, staging, publication, and VM entrypoints passed'
