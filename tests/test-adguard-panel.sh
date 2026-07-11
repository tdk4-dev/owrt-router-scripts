#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VPN_UI="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
VIEW="$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/adguard.js"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/adguard-panel.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/df" <<'EOF'
#!/bin/sh
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' '/dev/root 100000 78000 22000 78% /overlay'
EOF
chmod 755 "$TMP_DIR/bin/df"

generic="$(VPN_UI_DF_BIN="$TMP_DIR/bin/df" VPN_UI_HARDWARE_PROFILE=generic sh "$VPN_UI" adguard-status)"
printf '%s\n' "$generic" | grep -Fq '"installed":false'
printf '%s\n' "$generic" | grep -Fq '"install_supported":true'
printf '%s\n' "$generic" | grep -Fq '"can_install":false'
printf '%s\n' "$generic" | grep -Fq '"risk":"blocked"'
printf '%s\n' "$generic" | grep -Fq '"estimatedInstallBytes":33554432'

rd23="$(VPN_UI_DF_BIN="$TMP_DIR/bin/df" VPN_UI_HARDWARE_PROFILE=xiaomi-ax3000t-rd23 sh "$VPN_UI" adguard-status)"
printf '%s\n' "$rd23" | grep -Fq '"hardware_profile":"xiaomi-ax3000t-rd23"'
printf '%s\n' "$rd23" | grep -Fq '"install_supported":false'
printf '%s\n' "$rd23" | grep -Fq '"can_install":false'

grep -Fq 'optional network-wide DNS filtering service' "$VIEW"
grep -Fq 'Persistent storage' "$VIEW"
grep -Fq "this.callHelper(['adguard-install'])" "$VIEW"
grep -Fq 'data.can_install ? null' "$VIEW"
grep -Fq '!installed && supported' "$VIEW"
! grep -Fq 'opkg upgrade' "$VPN_UI"

printf 'AdGuard panel and storage eligibility checks passed\n'
