#!/bin/sh
# Lifecycle guard for retained legacy xray-transparent conffiles.
vpn_ui_transparent_running() {
  nft list table inet xray_transparent >/dev/null 2>&1 &&
    nft list set inet xray_transparent bypass4 >/dev/null 2>&1 &&
    nft list chain inet xray_transparent dns_prerouting 2>/dev/null |
      grep -q "redirect to :${ROUTER_DNS_PORT:-53}" &&
    nft list set inet xray_transparent vpn_ui_device_bypass4 >/dev/null 2>&1 &&
    nft list chain inet xray_transparent tproxy_prerouting 2>/dev/null |
      grep -q 'ip saddr @vpn_ui_device_bypass4' &&
    [ "$(nft list chain inet xray_transparent tproxy_prerouting 2>/dev/null |
      grep -c "tproxy.*:${XRAY_PORT:-12345}")" -ge 2 ] &&
    ip -4 rule show 2>/dev/null | grep -Eq 'fwmark (0x0*1|1)(/0xffffffff)? .*lookup 100' &&
    ip -4 route show table 100 2>/dev/null |
      grep -Eq '^local (default|0\.0\.0\.0/0) dev lo( |$)'
}

vpn_ui_start_legacy() {
  if vpn_ui_legacy_start "$@" &&
    "${VPN_UI_ROOT_PREFIX:-}/usr/sbin/vpn-ui" device-bypass-sync &&
    vpn_ui_transparent_running; then
    return 0
  fi
  stop >/dev/null 2>&1 || true
  return 1
}
