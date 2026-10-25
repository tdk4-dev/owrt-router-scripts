#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT="$ROOT_DIR/luci-vpn-ui/files/etc/init.d/xray-transparent"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-transparent-init.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state" "$TMP_ROOT/usr/sbin" "$TMP_ROOT/etc/xray"

cat > "$TMP_ROOT/bin/nft" <<'EOF'
#!/bin/sh
table="$VPN_UI_TEST_KERNEL_STATE/table"
case "$*" in
  '-f -')
    batch="$(cat)"
    [ "${VPN_UI_TEST_SYNC_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' "$batch" | awk '/^add element/ {print $7}' > "$VPN_UI_TEST_KERNEL_STATE/members"
    ;;
  'list table inet xray_transparent')
    [ -f "$table" ] && printf '%s\n' 'chain tproxy_prerouting {' 'type filter hook prerouting priority mangle;' ;;
  '-a list chain inet xray_transparent tproxy_prerouting')
    [ -f "$table" ] && printf '%s\n' 'ip saddr @vpn_ui_device_bypass4 accept' ;;
  'flush set inet xray_transparent vpn_ui_device_bypass4') : > "$VPN_UI_TEST_KERNEL_STATE/members" ;;
  'add element inet xray_transparent vpn_ui_device_bypass4 { 192.0.2.25 }')
    [ "${VPN_UI_TEST_SYNC_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' 192.0.2.25 >> "$VPN_UI_TEST_KERNEL_STATE/members" ;;
  'add set inet xray_transparent vpn_ui_device_bypass4 { type ipv4_addr; flags interval; }')
    : > "$VPN_UI_TEST_KERNEL_STATE/members" ;;
  'list set inet xray_transparent bypass4'|'list set inet xray_transparent vpn_ui_device_bypass4') [ -f "$table" ] ;;
  'list chain inet xray_transparent dns_prerouting')
    [ -f "$table" ] && printf '%s\n' 'udp dport 53 redirect to :53' ;;
  'list chain inet xray_transparent tproxy_prerouting')
    [ -f "$table" ] && printf '%s\n' \
      'ip saddr @vpn_ui_device_bypass4 accept' \
      'meta l4proto tcp tproxy to :12345' \
      'meta l4proto udp tproxy to :12345' ;;
  'delete table inet xray_transparent') rm -f "$table" "$VPN_UI_TEST_KERNEL_STATE/members" ;;
  'add table inet xray_transparent') : > "$table" ;;
  *)
    [ -f "$table" ] || exit 1
    case "$*" in *"${VPN_UI_TEST_NFT_FAIL_ON:-never-match}"*) exit 71 ;; esac
    ;;
esac
EOF

cat > "$TMP_ROOT/bin/ip" <<'EOF'
#!/bin/sh
rule="$VPN_UI_TEST_KERNEL_STATE/rule"
route="$VPN_UI_TEST_KERNEL_STATE/route"
case "$*" in
  '-4 rule show') [ ! -f "$rule" ] || printf '%s\n' '100: from all fwmark 0x1 lookup 100' ;;
  '-4 route show table 100') [ ! -f "$route" ] || printf '%s\n' 'local default dev lo scope host' ;;
  '-4 rule del fwmark 0x1 lookup 100') [ -f "$rule" ] || exit 1; rm -f "$rule" ;;
  '-4 route flush table 100') rm -f "$route" ;;
  '-4 rule add fwmark 0x1 lookup 100 pref 100') : > "$rule" ;;
  '-4 route add local 0.0.0.0/0 dev lo table 100') : > "$route" ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$TMP_ROOT/bin/nft" "$TMP_ROOT/bin/ip"

cat > "$TMP_ROOT/usr/sbin/vpn-ui" <<'EOF'
#!/bin/sh
[ "$1" = device-bypass-sync ] || exit 1
VPN_UI_SOURCE_ONLY=1 . "$VPN_UI_TEST_HELPER"
DHCP_LEASES_FILE="$VPN_UI_TEST_KERNEL_STATE/dhcp.leases"
ensure_device_bypass_nft
EOF
chmod 755 "$TMP_ROOT/usr/sbin/vpn-ui"
printf '%s\n' '02:00:00:00:00:25' > "$TMP_ROOT/etc/xray/vpn-ui-device-bypass-macs.txt"
printf '%s\n' '0 02:00:00:00:00:25 192.0.2.25 test *' > "$TMP_ROOT/state/dhcp.leases"
VPN_UI_TEST_HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
VPN_UI_ROOT_PREFIX="$TMP_ROOT"
export VPN_UI_TEST_HELPER VPN_UI_ROOT_PREFIX
PATH="$TMP_ROOT/bin:$PATH"
VPN_UI_TEST_KERNEL_STATE="$TMP_ROOT/state"
export PATH VPN_UI_TEST_KERNEL_STATE
. "$INIT"

grep -Fq 'EXTRA_COMMANDS="running"' "$INIT"
grep -Fq 'running Check whether complete transparent-proxy kernel state is present' "$INIT"
start
running
[ -f "$TMP_ROOT/state/table" ]
[ -f "$TMP_ROOT/state/rule" ]
[ -f "$TMP_ROOT/state/route" ]
grep -Fqx 192.0.2.25 "$TMP_ROOT/state/members"
restart
running
grep -Fqx 192.0.2.25 "$TMP_ROOT/state/members"
stop
! running
[ ! -e "$TMP_ROOT/state/table" ]
[ ! -e "$TMP_ROOT/state/rule" ]
[ ! -e "$TMP_ROOT/state/route" ]

VPN_UI_TEST_NFT_FAIL_ON='add chain inet xray_transparent tproxy_prerouting'
export VPN_UI_TEST_NFT_FAIL_ON
if start; then
  printf 'transparent init accepted an injected partial nft failure\n' >&2
  exit 1
fi
! running
[ ! -e "$TMP_ROOT/state/table" ]
[ ! -e "$TMP_ROOT/state/rule" ]
[ ! -e "$TMP_ROOT/state/route" ]

# A failed population is a failed start, with the partial routing table removed.
unset VPN_UI_TEST_NFT_FAIL_ON
VPN_UI_TEST_SYNC_FAIL=1
export VPN_UI_TEST_SYNC_FAIL
! start
! running
[ ! -e "$TMP_ROOT/state/table" ]
unset VPN_UI_TEST_SYNC_FAIL

grep -Fq 'The packaged transparent-proxy service is missing or unsafe.' \
  "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
! grep -Fq "cat > /etc/init.d/xray-transparent" \
  "$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

printf 'Packaged transparent-proxy init postcondition and partial-failure cleanup tests passed\n'
