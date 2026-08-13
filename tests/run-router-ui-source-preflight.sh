#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EXPECTED_SOURCE_SHA="${EXPECTED_SOURCE_SHA:?EXPECTED_SOURCE_SHA is required}"
ACTUAL_SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
PYTHONPYCACHEPREFIX="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-preflight-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX
trap 'rm -rf "$PYTHONPYCACHEPREFIX"' EXIT INT TERM

[ "$ACTUAL_SOURCE_SHA" = "$EXPECTED_SOURCE_SHA" ] || {
  printf 'ERROR: preflight source mismatch: expected %s, checked out %s\n' \
    "$EXPECTED_SOURCE_SHA" "$ACTUAL_SOURCE_SHA" >&2
  exit 1
}
[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ] || {
  printf 'ERROR: exact-SHA preflight requires a clean checkout\n' >&2
  exit 1
}

cd "$ROOT_DIR"

sh -n \
  bootstrap-router-ui-ipk-install.sh \
  luci-vpn-ui/install.sh \
  luci-vpn-ui/files/usr/sbin/vpn-ui \
  luci-vpn-ui/files/usr/sbin/vpn-ui-readonly \
  luci-vpn-ui/files/usr/sbin/vpn-ui-update \
  luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh \
  luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator \
  luci-vpn-ui/files/etc/init.d/premier-router-update-recovery \
  rescue-router-ui.sh \
  scripts/stage-router-release.sh \
  scripts/validate-staged-release.sh \
  tests/test-security-boundaries-0.7.11.sh \
  tests/test-updater-transaction-v2.sh \
  tests/test-updater-worker-start.sh \
  tests/test-xray-adopted-overlay.sh

node --check luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js
node --check luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js
node --check luci-vpn-ui/files/www/luci-static/resources/view/system/update.js
node --check luci-vpn-ui/files/www/luci-static/resources/view/status/include/35_vpn.js
node --check tests/test-router-ui-control-census.mjs
node --check tests/test-router-ui-state-rendering.mjs
node --check tests/test-tailscale-ping-ui.mjs
node --check tests/test-vpn-luci-adopted-apply.mjs
node --check tests/test-phase1-workflow-dependencies.mjs
python3 -m py_compile scripts/render-router-ui-install-guide.py tests/test-router-ui-collateral.py

node tests/test-router-ui-control-census.mjs
node tests/test-router-ui-state-rendering.mjs
node tests/test-tailscale-ping-ui.mjs
node tests/test-vpn-luci-adopted-apply.mjs
sh tests/test-security-boundaries-0.7.11.sh
sh tests/test-vpn-hotfixes.sh
sh tests/test-updater-transaction-v2.sh
sh tests/test-updater-worker-start.sh
sh tests/test-xray-adopted-overlay.sh
node tests/test-phase1-workflow-dependencies.mjs
python3 tests/test-router-ui-collateral.py

printf 'Router UI exact-SHA source preflight passed: %s\n' "$ACTUAL_SOURCE_SHA"
