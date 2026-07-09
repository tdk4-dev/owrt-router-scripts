#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INCLUDE_DIR="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/status/include"
PLAIN_INCLUDE="$INCLUDE_DIR/35_vpn.js"
UNDERSCORE_INCLUDE="$INCLUDE_DIR/_35_vpn.js"

test -f "$PLAIN_INCLUDE"
test -f "$UNDERSCORE_INCLUDE"
cmp -s "$PLAIN_INCLUDE" "$UNDERSCORE_INCLUDE"
grep -q "\['footer-info'\]" "$PLAIN_INCLUDE"
grep -q 'metadata.footer_label' "$PLAIN_INCLUDE"
grep -q 'metadata.support_level' "$PLAIN_INCLUDE"
grep -q 'metadata.registration_state' "$PLAIN_INCLUDE"

grep -q 'status/include/_35_vpn.js' "$ROOT_DIR/luci-vpn-ui/install.sh"
grep -q 'status/include/_35_vpn-0-7-0.js' "$ROOT_DIR/luci-vpn-ui/install.sh"
grep -q 'status/include/_35_vpn.js' "$ROOT_DIR/install-openwrt-vpn-ui.sh"
grep -q 'status/include/_35_vpn.js' "$ROOT_DIR/install-friend-vpn-panel.sh"
grep -q '_35_vpn.js' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"

if find "$ROOT_DIR/luci-vpn-ui/files/usr/share/ucode/luci/template/themes" -name footer.ut -print 2>/dev/null | grep -q .; then
  printf 'LuCI theme footer overrides must not be shipped by the project\n' >&2
  exit 1
fi
