#!/bin/sh
set -eu
umask 077

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BRIDGE_DIR="$SCRIPT_DIR/bridge"
VERSION_FILE="${VPN_UI_VERSION_FILE:-/usr/share/vpn-ui/version}"
OPENWRT_RELEASE_FILE="${VPN_UI_OPENWRT_RELEASE_FILE:-/etc/openwrt_release}"
SOURCE_VERSION="$(sed -n '1p' "$VERSION_FILE" 2>/dev/null | tr -d '\r\n')"
TARGET_VERSION="$(sed -n '1p' "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '\r\n')"
TARGET_PACKAGE_VERSION="$(sed -n '1p' "$SCRIPT_DIR/PACKAGE_VERSION" 2>/dev/null | tr -d '\r\n')"
LEGACY_WORKER_PID="${PPID:-}"
LEGACY_WORKER_START_ID=""
LEGACY_WORKER_SHA256=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [ "$(id -u)" != 0 ] && [ "${PREMIER_ROUTER_HOST_TEST:-0}" != 1 ]; then
  die "run this bridge as root on OpenWrt"
fi
[ -f "$OPENWRT_RELEASE_FILE" ] || die "this does not appear to be OpenWrt"
[ "${TARGET_VERSION%%-rc.*}" = 0.7.11 ] || die "compatibility bundle target is not on the 0.7.11 line"
[ -n "$TARGET_PACKAGE_VERSION" ] || die "compatibility bundle package version is missing"
case "$SOURCE_VERSION" in
  0.7.9|0.7.10) ;;
  *) die "the legacy in-panel bridge supports only exact 0.7.9 or 0.7.10 sources" ;;
esac

for file in \
  router-release-manifest.json \
  router-release-manifest.json.sig \
  trusted-release.pub \
  release-key-id \
  router-candidate-validator \
  update-lib.sh \
  vpn-ui-update
do
  [ -s "$BRIDGE_DIR/$file" ] || die "compatibility bundle is missing $file"
done
for package in premier-router-core luci-app-premier-router premier-router-setup; do
  file="${package}_${TARGET_PACKAGE_VERSION}_all.ipk"
  [ -s "$BRIDGE_DIR/$file" ] || die "compatibility bundle is missing $file"
done
[ -n "${VPN_UI_ROLLBACK_MARKER:-}" ] ||
  die "the legacy worker did not provide a rollback marker"
[ -n "$LEGACY_WORKER_PID" ] && [ -r "/proc/$LEGACY_WORKER_PID/stat" ] ||
  die "the legacy worker process is not observable"
LEGACY_WORKER_START_ID="$(awk '{print $22}' "/proc/$LEGACY_WORKER_PID/stat")"
LEGACY_WORKER_SHA256="$(sha256sum /usr/sbin/vpn-ui-update | awk '{print $1}')"
tr '\000' ' ' < "/proc/$LEGACY_WORKER_PID/cmdline" | grep -q 'vpn-ui-update' ||
  die "the parent process is not the exact legacy updater worker"

EXISTING_RECOVERY="$(find /root/router-ui-backups -maxdepth 1 -type f \
  -name 'openwrt-before-router-ui-0.7.11-*.tar.gz' 2>/dev/null |
  sort | tail -n 1)"
if [ -n "$EXISTING_RECOVERY" ]; then
  tar -tzf "$EXISTING_RECOVERY" >/dev/null 2>&1 ||
    die "the legacy worker recovery archive is invalid"
fi

chmod 700 "$BRIDGE_DIR/vpn-ui-update" "$BRIDGE_DIR/update-lib.sh" \
  "$BRIDGE_DIR/router-candidate-validator"
VPN_UI_UPDATE_LIB="$BRIDGE_DIR/update-lib.sh" \
VPN_UI_UPDATE_SELF="$BRIDGE_DIR/vpn-ui-update" \
VPN_UI_RELEASE_PUBLIC_KEY="$BRIDGE_DIR/trusted-release.pub" \
VPN_UI_RELEASE_KEY_ID_FILE="$BRIDGE_DIR/release-key-id" \
VPN_UI_EXISTING_CONFIG_RECOVERY="$EXISTING_RECOVERY" \
  "$BRIDGE_DIR/vpn-ui-update" apply-local "$BRIDGE_DIR" \
    "$BRIDGE_DIR/router-release-manifest.json" \
    "$BRIDGE_DIR/router-release-manifest.json.sig" \
    legacy-bridge legacy-worker

[ "$(sed -n '1p' "$VERSION_FILE" | tr -d '\r\n')" = "$TARGET_VERSION" ] ||
  die "bridge supervisor returned success without installing $TARGET_VERSION"
[ "$(awk '{print $22}' "/proc/$LEGACY_WORKER_PID/stat" 2>/dev/null)" = "$LEGACY_WORKER_START_ID" ] ||
  die "the original legacy updater worker exited before candidate validation completed"
TRANSACTION="$(sed -n '1p' /root/premier-router-updates/active-transaction 2>/dev/null)"
[ -n "$TRANSACTION" ] || die "bridge transaction evidence is missing"
cat > "/root/premier-router-updates/$TRANSACTION/legacy-worker-handoff.json" <<EOF
{"source_version":"$SOURCE_VERSION","legacy_worker_pid":$LEGACY_WORKER_PID,"legacy_worker_start_id":"$LEGACY_WORKER_START_ID","legacy_worker_script_sha256":"$LEGACY_WORKER_SHA256","alive_after_candidate_validation":true}
EOF
printf 'Router UI %s bridge installed and validated from %s.\n' "$TARGET_VERSION" "$SOURCE_VERSION"
