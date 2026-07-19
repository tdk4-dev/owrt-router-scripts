#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INCLUDE_DIR="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/status/include"
PLAIN_INCLUDE="$INCLUDE_DIR/35_vpn.js"

test -f "$PLAIN_INCLUDE"
test "$(find "$INCLUDE_DIR" -maxdepth 1 -type f -name '*vpn*.js' | wc -l | tr -d ' ')" = 1
grep -q "\['footer-info'\]" "$PLAIN_INCLUDE"
grep -q 'metadata.footer_label' "$PLAIN_INCLUDE"
grep -q 'metadata.support_level' "$PLAIN_INCLUDE"
grep -q 'metadata.registration_state' "$PLAIN_INCLUDE"
grep -q "require tools.router_footer as routerFooter" "$PLAIN_INCLUDE"
grep -q 'routerFooter.apply(metadata)' "$PLAIN_INCLUDE"

FOOTER_HELPER="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/tools/router_footer.js"
test -f "$FOOTER_HELPER"
grep -q "document.querySelector('footer')" "$FOOTER_HELPER"
grep -q "footer.insertBefore(row, footer.firstChild)" "$FOOTER_HELPER"
grep -q "Registration: %s" "$FOOTER_HELPER"

for panel in \
  "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js" \
  "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js" \
  "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/update.js" \
  "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/reset.js"
do
  grep -q 'require tools.router_footer as routerFooter' "$panel"
  grep -q 'routerFooter.apply' "$panel"
  ! grep -q 'router-panel-footer' "$panel"
done

grep -q 'copy_tree_file_modes.*luci-vpn-ui/files/www' "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
grep -q '/www/luci-static/resources/view/status/include/_35_vpn.js' "$ROOT_DIR/scripts/build-openwrt-ipks.sh"
grep -q 'premier-router-core_0.7.11-1_all.ipk' "$ROOT_DIR/luci-vpn-ui/install.sh"
grep -q 'luci-app-premier-router_0.7.11-1_all.ipk' "$ROOT_DIR/luci-vpn-ui/install.sh"
! grep -q 'copy_file.*status/include' "$ROOT_DIR/luci-vpn-ui/install.sh"
grep -q 'test ! -e /www/luci-static/resources/view/status/include/_35_vpn.js' "$ROOT_DIR/install-friend-vpn-panel.sh"
grep -q '/www/luci-static/resources/view/status/include/_35_vpn.js' \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
grep -q '/www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js' \
  "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"

if find "$ROOT_DIR/luci-vpn-ui/files/usr/share/ucode/luci/template/themes" -name footer.ut -print 2>/dev/null | grep -q .; then
  printf 'LuCI theme footer overrides must not be shipped by the project\n' >&2
  exit 1
fi
