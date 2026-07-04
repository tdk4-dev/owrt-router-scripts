#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn-0-7-6.js"

grep -q 'flow_json=""' "$HELPER"
grep -q '"encryption": "none"\$flow_json' "$HELPER"
! grep -q 'P_FLOW="xtls-rprx-vision"' "$HELPER"
grep -q '"port": "8080"' "$HELPER"
grep -q 'active_proxy_probe_ms' "$HELPER"
grep -q 'tcp %s\\n' "$HELPER"

count="$(grep -c 'ui.addNotification' "$VIEW")"
[ "$count" -eq 1 ] || {
  printf 'expected one ui.addNotification call site, found %s\n' "$count" >&2
  exit 1
}
grep -q 'clearNotifications' "$VIEW"
grep -q "ping.indexOf('tcp ') == 0" "$VIEW"

printf 'VPN 0.7.6 hotfix static checks passed\n'
