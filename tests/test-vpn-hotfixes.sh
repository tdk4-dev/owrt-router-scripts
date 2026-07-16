#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js"
SETUP_CGI="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
SETUP_APP="$ROOT_DIR/firstboot-wizard/www/app.js"
SETUP_SERVER="$ROOT_DIR/firstboot-wizard/server.mjs"
RELEASE_INSTALLER="$ROOT_DIR/install-router-ui-release.sh"
VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION")"
INSTALLED_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/files/usr/share/vpn-ui/version")"

[ "$VERSION" = "0.7.9.1" ]
[ "$INSTALLED_VERSION" = "$VERSION" ]

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
grep -q '"configured":false' "$HELPER"
grep -q 'configuration is not enabled' "$HELPER"
grep -q '"configured":true' "$HELPER"
grep -Fq '\(system\/update\)".*/\1/p' "$RELEASE_INSTALLER"
grep -Fq '\(system\/update-[^"][^"]*\)".*/\1/p' "$RELEASE_INSTALLER"

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

printf 'VPN 0.7.9.1 hotfix static checks passed\n'
