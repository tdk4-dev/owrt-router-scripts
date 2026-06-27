#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

VPN_UI_LIB_ONLY=1 . "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"

P_HOST="example.com"
P_SNI="example.com"
P_FINGERPRINT="firefox"
P_PUBLIC_KEY="test-public-key"
P_SHORT_ID="abcd"
P_SPIDERX="/"
P_UUID="11111111-1111-1111-1111-111111111111"
P_PORT="443"
P_FLOW="xtls-rprx-vision"
P_VPS_IP="203.0.113.10"
LAN_IP="10.77.0.1"

DOMAINS_EMPTY="$TMP_DIR/direct-domains-empty.txt"
DOMAINS_FILLED="$TMP_DIR/direct-domains-filled.txt"
IPS_EMPTY="$TMP_DIR/direct-ips-empty.txt"
CFG_EMPTY="$TMP_DIR/xray-empty.json"
CFG_FILLED="$TMP_DIR/xray-filled.json"

: > "$DOMAINS_EMPTY"
: > "$IPS_EMPTY"
printf '%s\n' 'example.org' > "$DOMAINS_FILLED"

render_xray_config "$CFG_EMPTY" "$DOMAINS_EMPTY" "$IPS_EMPTY"
domain_rule_count="$(grep -F -c '"domain": [' "$CFG_EMPTY")"
[ "$domain_rule_count" -eq 1 ]
! awk '
  /"domain"[[:space:]]*:[[:space:]]*\[/ { in_domain = 1; count = 0; next }
  in_domain && /]/ {
    if (count == 0) found = 1
    in_domain = 0
  }
  in_domain && /"/ { count++ }
  END { exit found ? 0 : 1 }
' "$CFG_EMPTY"

render_xray_config "$CFG_FILLED" "$DOMAINS_FILLED" "$IPS_EMPTY"
grep -q '"example.org"' "$CFG_FILLED"
grep -q '"outboundTag": "direct"' "$CFG_FILLED"

printf '%s\n' "vpn-ui empty direct-domain renderer regression test passed"
