#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VPN_UI="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
BUILD_IPKS="$ROOT_DIR/scripts/build-openwrt-ipks.sh"
FIRSTBOOT="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
DEFAULTS="$ROOT_DIR/image-overlay/etc/uci-defaults/99-openwrt-fin0-firstboot"
MIGRATION="$ROOT_DIR/migrate-openwrt-vpn-routes.sh"

for contract in \
  'service_running "$XRAY_SERVICE"' \
  'transparent_running' \
  'restore_xray_lifecycle_state' \
  'exact UCI, daemon, transparent-proxy, and reboot pre-state restored' \
  'start returned without a running daemon' \
  'start returned without complete transparent-proxy kernel state' \
  'stop returned while the daemon remained running' \
  'stop returned while transparent-proxy kernel state remained active'; do
  grep -Fq "$contract" "$VPN_UI"
done

grep -Fq 'services_match || {' "$UPDATER"
grep -Fq 'service_postcondition_failed' "$UPDATER"
grep -Fq 'restore_transparent_init_prestate' "$UPDATER"
grep -Fq 'xray-transparent-prestate' "$BUILD_IPKS"
for service in xray xray-exit-st xray-transparent; do
  grep -Fq "cron rpcd uhttpd xray xray-exit-st xray-transparent" "$UPDATER"
done

grep -Fq '/usr/sbin/vpn-ui xray on' "$FIRSTBOOT"
grep -Fq '/usr/sbin/vpn-ui xray off' "$FIRSTBOOT"
grep -Fq 'Could not enable Xray and transparent proxying' "$FIRSTBOOT"
grep -Fq 'Could not keep Xray and transparent proxying disabled' "$FIRSTBOOT"
! grep -Eq '/etc/init\.d/(xray|xray-transparent) (start|stop|restart|enable|disable).*\|\| true' "$FIRSTBOOT"

grep -Fq '! /etc/init.d/xray running' "$DEFAULTS"
grep -Fq '! /etc/init.d/xray-transparent running' "$DEFAULTS"
grep -Fq '! /etc/init.d/xray enabled' "$DEFAULTS"
grep -Fq '! /etc/init.d/xray-transparent enabled' "$DEFAULTS"
grep -Fq "uci set xray.enabled.enabled='0'" "$DEFAULTS"

grep -Fq 'capture_xray_runtime_state' "$MIGRATION"
grep -Fq 'verify_captured_xray_runtime_state' "$MIGRATION"
grep -Fq 'exact configuration, daemon, transparent-proxy, and reboot pre-state restored' "$MIGRATION"
grep -Fq 'service-state.tsv' "$MIGRATION"
! grep -Eq '/etc/init\.d/(xray|xray-transparent|xray-exit-st) restart .*\|\| true' "$MIGRATION"

for setup in "$ROOT_DIR/setup-openwrt-x86-fin0.sh" "$ROOT_DIR/setup-rd23-vpn-ap.sh"; do
  grep -Fq 'kernel_state_present()' "$setup"
  grep -Fq 'EXTRA_COMMANDS="running"' "$setup"
  grep -Fq '/etc/init.d/xray running' "$setup"
  grep -Fq '/etc/init.d/xray-transparent running' "$setup"
done

printf 'Xray and transparent-proxy mutation call-path census passed\n'
