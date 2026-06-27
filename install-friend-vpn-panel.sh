#!/bin/sh
set -eu

# Install the same VPN and Tailscale LuCI panels on another OpenWrt router.
#
# Usage:
#   ./install-friend-vpn-panel.sh valera-owrt
#   ./install-friend-vpn-panel.sh root@192.168.1.1
#
# The target must already have working root SSH, LuCI, Xray, and Tailscale.
# Existing VPN profiles and routing lists are preserved by the transactional
# panel installer. A full sysupgrade backup is copied to router-backups/.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROUTER_HOST="${1:-${ROUTER_HOST:-valera-owrt}}"

case "$ROUTER_HOST" in
  ""|localhost|127.0.0.1)
    printf 'ERROR: provide the friend router SSH alias, IP, or root@host\n' >&2
    exit 1
    ;;
esac

printf 'Checking friend router prerequisites on %s...\n' "$ROUTER_HOST"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$ROUTER_HOST" '
  set -eu
  [ "$(id -u)" = "0" ]
  [ -f /etc/openwrt_release ]
  command -v sysupgrade >/dev/null
  command -v tailscale >/dev/null
  command -v xray >/dev/null || [ -x /usr/local/bin/xray-latest ]
  [ -d /www/luci-static/resources/view/network ]
  /etc/init.d/rpcd enabled >/dev/null 2>&1 || true
'

ROUTER_HOST="$ROUTER_HOST" \
PANEL_SOURCE=local \
MAKE_SYSUPGRADE_BACKUP=1 \
INSTALL_GEOSITE=1 \
UPDATE_GEOSITE=0 \
  "$SCRIPT_DIR/install-openwrt-vpn-ui.sh"

printf '\nValidating VPN and Tailscale panels on %s...\n' "$ROUTER_HOST"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$ROUTER_HOST" '
  set -eu
  test "$(cat /usr/share/vpn-ui/version)" = "0.7.5"
  /usr/sbin/vpn-ui check | grep -q "\"ok\":true"
  /usr/sbin/vpn-ui tailscale-status | grep -q "\"tailscale\":"
  grep -q "network/vpn-0-7-0" /usr/share/luci/menu.d/luci-app-vpn-ui.json
  grep -q "network/tailscale-0-7-5" /usr/share/luci/menu.d/luci-app-vpn-ui.json
  grep -q "system/update-0-7-3" /usr/share/luci/menu.d/luci-app-vpn-ui.json
  test -f /www/luci-static/resources/view/network/vpn-0-7-0.js
  test -f /www/luci-static/resources/view/network/tailscale-0-7-5.js
  test -f /www/luci-static/resources/view/system/update-0-7-3.js
  test -f /www/luci-static/resources/view/status/include/35_vpn-0-7-0.js
  test -f /www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js
'

printf '\nFriend router panel installation completed.\n'
printf 'Open LuCI, then use VPN Panel, Tailscale, and the top-level Update menu.\n'
