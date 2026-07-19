#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VIEW_DIR="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view"
MENU="$ROOT_DIR/luci-vpn-ui/files/usr/share/luci/menu.d/luci-app-vpn-ui.json"
INSTALLER="$ROOT_DIR/luci-vpn-ui/install.sh"
RELEASE_INSTALLER="$ROOT_DIR/install-router-ui-release.sh"
BUNDLE_BUILDER="$ROOT_DIR/make-vpn-ui-release-bundle.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/release-vpn-panel.yml"
PLAIN_INCLUDE="$VIEW_DIR/status/include/35_vpn.js"

test -f "$VIEW_DIR/network/vpn.js"
test -f "$VIEW_DIR/network/tailscale.js"
test -f "$VIEW_DIR/network/adguard.js"
test -f "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/tools/router_footer.js"
test -f "$VIEW_DIR/system/update.js"
test -f "$PLAIN_INCLUDE"
test "$(find "$VIEW_DIR/status/include" -maxdepth 1 -type f -name '*vpn*.js' | wc -l | tr -d ' ')" = 1

versioned_assets="$(find "$VIEW_DIR" -type f -name '*[0-9]-[0-9]*.js' -print)"
if [ -n "$versioned_assets" ]; then
  printf 'versioned LuCI asset filenames are not allowed:\n%s\n' "$versioned_assets" >&2
  exit 1
fi

grep -q '"path":[[:space:]]*"network/vpn"' "$MENU"
grep -q '"path":[[:space:]]*"network/tailscale"' "$MENU"
grep -q '"path":[[:space:]]*"network/adguard"' "$MENU"
grep -q '"path":[[:space:]]*"system/update"' "$MENU"
! grep -Eq '"path":[[:space:]]*"[^"]*[0-9]+-[0-9]+' "$MENU"

grep -q 'resources/view/network/vpn.js' "$WORKFLOW"
grep -q 'resources/view/network/tailscale.js' "$WORKFLOW"
grep -q 'resources/view/system/update.js' "$WORKFLOW"
grep -q 'resources/view/status/include/35_vpn.js' "$WORKFLOW"
! grep -q 'resources/view/status/include/_35_vpn.js' "$WORKFLOW"

grep -q 'network/vpn.js' "$INSTALLER"
grep -q 'network/tailscale.js' "$INSTALLER"
grep -q 'network/adguard.js' "$INSTALLER"
grep -q 'tools/router_footer.js' "$INSTALLER"
grep -q 'system/update.js' "$INSTALLER"
grep -q 'status/include/35_vpn.js' "$INSTALLER"
grep -q '/www/luci-static/resources/view/status/include/_35_vpn.js' "$INSTALLER"
grep -q 'rm -f /www/luci-static/resources/view/network/vpn-0-7-6.js' "$INSTALLER"
grep -q '/www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js' "$INSTALLER"
! grep -q 'copy_file.*status/include/_35_vpn.js' "$INSTALLER"

extract_update_view() {
  sed -n \
    -e 's/.*"path":[[:space:]]*"\(system\/update\)".*/\1/p' \
    -e 's/.*"path":[[:space:]]*"\(system\/update-[^"][^"]*\)".*/\1/p' |
    sed -n '1p'
}

update_view="$(extract_update_view < "$MENU")"
[ "$update_view" = "system/update" ]
historical_view="$(printf '%s\n' '{"path":"system/update-0-7-9"}' | extract_update_view)"
[ "$historical_view" = "system/update-0-7-9" ]
[ -z "$(printf '%s\n' '{"path":"system/updateanything"}' | extract_update_view)" ]
[ -z "$(printf '%s\n' '{"path":"system/update/other"}' | extract_update_view)" ]
[ -z "$(printf '%s\n' '{"path":"system/other-update"}' | extract_update_view)" ]
grep -q '"path".*"system/update"' "$RELEASE_INSTALLER"
grep -q '^export COPYFILE_DISABLE=1$' "$BUNDLE_BUILDER"
grep -Fq 'exec "$ROOT_DIR/scripts/stage-router-release.sh"' "$BUNDLE_BUILDER"
printf 'Stable LuCI asset checks passed\n'
