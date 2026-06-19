#!/bin/ash
set -eu

# Run this script directly on an already-running OpenWrt router as root.
#
# Latest stable release:
#   sh install-router-ui-release.sh
#
# Pin a release (including the current 0.6.0 test release):
#   ROUTER_UI_VERSION=0.6.0 sh install-router-ui-release.sh

REPO="${ROUTER_UI_REPO:-tdk4-dev/owrt-router-scripts}"
REQUESTED_VERSION="${ROUTER_UI_VERSION:-}"
BUNDLE="luci-vpn-ui.tar.gz"
TS="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="/tmp/router-ui-release-$TS"
BACKUP_DIR="/root/router-ui-backups"
MARKER="$WORK_DIR/rollback-marker"
LOG_FILE="/tmp/router-ui-release-install.log"
BEFORE_ROLLBACK_SUM=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

fetch() {
  local url="$1"
  local dst="$2"
  local attempt=1

  while [ "$attempt" -le 3 ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -4 -fsSL --proto '=https' --connect-timeout 10 --max-time 120 \
        "$url" -o "$dst" && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -T 120 -qO "$dst" "$url" && return 0
    elif command -v uclient-fetch >/dev/null 2>&1; then
      uclient-fetch -T 120 -q -O "$dst" "$url" && return 0
    else
      die "curl, wget, or uclient-fetch is required"
    fi
    rm -f "$dst"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
  return 1
}

validate_archive_paths() {
  tar -tzf "$1" |
    awk '
      /^\// { bad=1 }
      /(^|\/)\.\.(\/|$)/ { bad=1 }
      END { exit bad ? 1 : 0 }
    '
}

rollback_failed_install() {
  local rollback=""
  if [ -f "$MARKER" ]; then
    rollback="$(sed -n '1p' "$MARKER")"
  elif [ -x /root/rollback-vpn-ui.sh ]; then
    current_sum="$(sha256sum /root/rollback-vpn-ui.sh 2>/dev/null | awk '{ print $1 }')"
    if [ -z "$BEFORE_ROLLBACK_SUM" ] || [ "$current_sum" != "$BEFORE_ROLLBACK_SUM" ]; then
      rollback="/root/rollback-vpn-ui.sh"
    fi
  fi
  if [ -n "$rollback" ] && [ -x "$rollback" ]; then
    printf 'Installation failed; restoring the panel snapshot with %s\n' "$rollback" >&2
    sh "$rollback" >>"$LOG_FILE" 2>&1 || true
  fi
}

[ "$(id -u)" = "0" ] || die "run this script as root on OpenWrt"
[ -f /etc/openwrt_release ] || die "this does not appear to be OpenWrt"
command -v sysupgrade >/dev/null 2>&1 || die "sysupgrade is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
[ ! -f /root/rollback-vpn-ui.sh ] ||
  BEFORE_ROLLBACK_SUM="$(sha256sum /root/rollback-vpn-ui.sh | awk '{ print $1 }')"

mkdir -p "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$WORK_DIR" "$BACKUP_DIR"

if [ -n "$REQUESTED_VERSION" ]; then
  RELEASE_BASE="https://github.com/$REPO/releases/download/vpn-panel-v$REQUESTED_VERSION"
else
  RELEASE_BASE="https://github.com/$REPO/releases/latest/download"
fi

printf 'Reading release metadata from %s\n' "$RELEASE_BASE"
fetch "$RELEASE_BASE/vpn-ui-version.txt" "$WORK_DIR/version" ||
  die "could not download release version"
VERSION="$(sed -n '1p' "$WORK_DIR/version" | tr -d '\r\n')"
[ -n "$VERSION" ] || die "release version is empty"
[ -z "$REQUESTED_VERSION" ] || [ "$VERSION" = "$REQUESTED_VERSION" ] ||
  die "requested $REQUESTED_VERSION but release metadata reports $VERSION"

printf 'Downloading Router UI %s\n' "$VERSION"
fetch "$RELEASE_BASE/$BUNDLE" "$WORK_DIR/$BUNDLE" ||
  die "could not download release bundle"
fetch "$RELEASE_BASE/$BUNDLE.sha256" "$WORK_DIR/$BUNDLE.sha256" ||
  die "could not download release checksum"

EXPECTED="$(awk '{ print $1 }' "$WORK_DIR/$BUNDLE.sha256" | sed -n '1p')"
ACTUAL="$(sha256sum "$WORK_DIR/$BUNDLE" | awk '{ print $1 }')"
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] ||
  die "release checksum verification failed"
validate_archive_paths "$WORK_DIR/$BUNDLE" ||
  die "release archive contains unsafe paths"

FULL_BACKUP="$BACKUP_DIR/openwrt-before-router-ui-$VERSION-$TS.tar.gz"
printf 'Creating mandatory full OpenWrt backup: %s\n' "$FULL_BACKUP"
TEMP_BACKUP="/tmp/openwrt-before-router-ui-$VERSION-$TS.tar.gz"
rm -f "$TEMP_BACKUP"
sysupgrade -b "$TEMP_BACKUP" >/tmp/router-ui-sysupgrade-backup.log 2>&1 || {
  rm -f "$TEMP_BACKUP"
  die "could not create full OpenWrt backup"
}
[ -s "$TEMP_BACKUP" ] || {
  rm -f "$TEMP_BACKUP"
  die "full OpenWrt backup is empty"
}
tar -tzf "$TEMP_BACKUP" >/dev/null 2>&1 || {
  rm -f "$TEMP_BACKUP"
  die "full OpenWrt backup validation failed"
}
BACKUP_BYTES="$(wc -c < "$TEMP_BACKUP" | tr -d ' ')"
BACKUP_SIZE_KB=$(((BACKUP_BYTES + 1023) / 1024))
BACKUP_FREE_KB="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
[ -n "$BACKUP_FREE_KB" ] && [ "$BACKUP_FREE_KB" -ge $((BACKUP_SIZE_KB + 2048)) ] || {
  rm -f "$TEMP_BACKUP"
  die "not enough persistent free space for the verified OpenWrt backup"
}
cp "$TEMP_BACKUP" "$FULL_BACKUP" || {
  rm -f "$TEMP_BACKUP" "$FULL_BACKUP"
  die "could not persist the verified OpenWrt backup"
}
rm -f "$TEMP_BACKUP"
tar -tzf "$FULL_BACKUP" >/dev/null 2>&1 || {
  rm -f "$FULL_BACKUP"
  die "persisted OpenWrt backup validation failed"
}
BACKUP_SUM="$(sha256sum "$FULL_BACKUP" | awk '{ print $1 }')"
printf '%s  %s\n' "$BACKUP_SUM" "$(basename "$FULL_BACKUP")" > "$FULL_BACKUP.sha256"
chmod 600 "$FULL_BACKUP" "$FULL_BACKUP.sha256"

tar -xzf "$WORK_DIR/$BUNDLE" -C "$WORK_DIR" ||
  die "could not extract release"
INSTALLER="$WORK_DIR/luci-vpn-ui/install.sh"
[ -f "$INSTALLER" ] || die "release is missing install.sh"
[ "$(sed -n '1p' "$WORK_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')" = "$VERSION" ] ||
  die "release bundle version does not match metadata"

printf 'Installing Router UI %s transactionally\n' "$VERSION"
if ! VPN_UI_ROLLBACK_MARKER="$MARKER" SKIP_SYSUPGRADE_BACKUP=1 \
  INSTALL_GEOSITE=1 UPDATE_GEOSITE=0 sh "$INSTALLER" >"$LOG_FILE" 2>&1; then
  rollback_failed_install
  die "installation failed safely; inspect $LOG_FILE"
fi

[ "$(cat /usr/share/vpn-ui/version 2>/dev/null)" = "$VERSION" ] || {
  rollback_failed_install
  die "installed version validation failed"
}
/usr/sbin/vpn-ui check | grep -q '"ok":true' || {
  rollback_failed_install
  die "VPN configuration validation failed"
}
/usr/sbin/vpn-ui tailscale-status | grep -q '"ok":true' || {
  rollback_failed_install
  die "Tailscale panel validation failed"
}

rm -rf "$WORK_DIR"
printf '\nRouter UI %s installed and validated.\n' "$VERSION"
printf 'Full backup: %s\n' "$FULL_BACKUP"
printf 'Panel rollback: sh /root/rollback-vpn-ui.sh\n'
