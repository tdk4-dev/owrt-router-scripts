#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn-0-7-6.js"
SETUP_CGI="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
SETUP_APP="$ROOT_DIR/firstboot-wizard/www/app.js"
SETUP_SERVER="$ROOT_DIR/firstboot-wizard/server.mjs"

grep -q 'flow_json=""' "$HELPER"
grep -q '"encryption": "none"\$flow_json' "$HELPER"
! grep -q 'P_FLOW="xtls-rprx-vision"' "$HELPER"
grep -q '"port": "8080"' "$HELPER"
grep -q 'active_proxy_probe_ms' "$HELPER"
grep -q 'tcp %s\\n' "$HELPER"
grep -q 'direct_domain_rule_json=""' "$HELPER"
grep -q '\[ -n "$direct_domain_json" \]' "$HELPER"
grep -q 'XRAY_ACCESS_LOG_MAX_BYTES=1048576' "$HELPER"
grep -q 'cap_runtime_file "$XRAY_ACCESS_LOG"' "$HELPER"
grep -q 'harden_adguard_querylog' "$HELPER"
grep -q 'file_enabled: false' "$ROOT_DIR/setup-openwrt-x86-fin0.sh"
grep -q 'interval: 24h' "$ROOT_DIR/setup-openwrt-x86-fin0.sh"
grep -q 'file_enabled: false' "$SETUP_CGI"
grep -q 'interval: 24h' "$SETUP_CGI"

count="$(grep -c 'ui.addNotification' "$VIEW")"
[ "$count" -eq 1 ] || {
  printf 'expected one ui.addNotification call site, found %s\n' "$count" >&2
  exit 1
}
grep -q 'clearNotifications' "$VIEW"
grep -q "ping.indexOf('tcp ') == 0" "$VIEW"

grep -q 'vless://\*|https://\*' "$SETUP_CGI"
grep -q 'vpn-ui subscription-add' "$SETUP_CGI"
grep -q "startsWith('https://')" "$SETUP_APP"
grep -q "startsWith('https://')" "$SETUP_SERVER"

printf 'VPN 0.7.8 hotfix static checks passed\n'
