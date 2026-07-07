#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VIEW_DIR="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view"
MENU="$ROOT_DIR/luci-vpn-ui/files/usr/share/luci/menu.d/luci-app-vpn-ui.json"
INSTALLER="$ROOT_DIR/luci-vpn-ui/install.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/release-vpn-panel.yml"
PLAIN_INCLUDE="$VIEW_DIR/status/include/35_vpn.js"
UNDERSCORE_INCLUDE="$VIEW_DIR/status/include/_35_vpn.js"

test -f "$VIEW_DIR/network/vpn.js"
test -f "$VIEW_DIR/network/tailscale.js"
test -f "$VIEW_DIR/system/update.js"
test -f "$PLAIN_INCLUDE"
test -f "$UNDERSCORE_INCLUDE"
cmp -s "$PLAIN_INCLUDE" "$UNDERSCORE_INCLUDE"

versioned_assets="$(find "$VIEW_DIR" -type f -name '*[0-9]-[0-9]*.js' -print)"
if [ -n "$versioned_assets" ]; then
  printf 'versioned LuCI asset filenames are not allowed:\n%s\n' "$versioned_assets" >&2
  exit 1
fi

grep -q '"path":[[:space:]]*"network/vpn"' "$MENU"
grep -q '"path":[[:space:]]*"network/tailscale"' "$MENU"
grep -q '"path":[[:space:]]*"system/update"' "$MENU"
! grep -Eq '"path":[[:space:]]*"[^"]*[0-9]+-[0-9]+' "$MENU"

grep -q 'resources/view/network/vpn.js' "$WORKFLOW"
grep -q 'resources/view/network/tailscale.js' "$WORKFLOW"
grep -q 'resources/view/system/update.js' "$WORKFLOW"
grep -q 'resources/view/status/include/35_vpn.js' "$WORKFLOW"
grep -q 'resources/view/status/include/_35_vpn.js' "$WORKFLOW"

grep -q 'network/vpn.js' "$INSTALLER"
grep -q 'network/tailscale.js' "$INSTALLER"
grep -q 'system/update.js' "$INSTALLER"
grep -q 'status/include/35_vpn.js' "$INSTALLER"
grep -q 'status/include/_35_vpn.js' "$INSTALLER"
grep -q 'rm -f /www/luci-static/resources/view/network/vpn-0-7-6.js' "$INSTALLER"
grep -q 'rm -f /www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js' "$INSTALLER"

printf 'Stable LuCI asset checks passed\n'
