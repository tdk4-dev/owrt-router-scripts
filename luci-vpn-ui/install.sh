#!/bin/ash
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/files"
VERSION="$(sed -n '1p' "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '\r\n' || true)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/vpn-ui-preinstall-$TS"
ROLLBACK="/root/rollback-vpn-ui-$TS.sh"
LATEST_ROLLBACK="/root/rollback-vpn-ui.sh"
FULL_BACKUP_DIR="/root/router-ui-backups"
FULL_BACKUP=""
SKIP_SYSUPGRADE_BACKUP="${SKIP_SYSUPGRADE_BACKUP:-0}"
VPN_UI_ROLLBACK_MARKER="${VPN_UI_ROLLBACK_MARKER:-}"
ROLLBACK_READY=0
INSTALL_COMPLETE=0
VPN_UI_REPO="${VPN_UI_REPO:-tdk4-dev/owrt-router-scripts}"
VPN_UI_BRANCH="${VPN_UI_BRANCH:-codex/vpn-panel-installer}"
VPN_UI_REF="${VPN_UI_REF:-refs/heads/$VPN_UI_BRANCH}"
VPN_UI_RAW_BASE="${VPN_UI_RAW_BASE:-https://raw.githubusercontent.com/$VPN_UI_REPO/$VPN_UI_REF/luci-vpn-ui/files}"
INSTALL_GEOSITE="${INSTALL_GEOSITE:-1}"
UPDATE_GEOSITE="${UPDATE_GEOSITE:-0}"
GEOSITE_FILE="${GEOSITE_FILE:-/usr/share/xray/geosite.dat}"
GEOSITE_URL="${GEOSITE_URL:-https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat}"
GEOSITE_MIN_BYTES="${GEOSITE_MIN_BYTES:-1048576}"

TOUCHED_PATHS="/usr/sbin/vpn-ui
/usr/sbin/vpn-ui-update
/www/luci-static/resources/view/network/vpn.js
/www/luci-static/resources/view/network/tailscale.js
/www/luci-static/resources/view/system/update.js
/www/luci-static/resources/view/status/include/35_vpn.js
/www/luci-static/resources/view/status/include/_35_vpn.js
/www/luci-static/resources/view/network/vpn-0-7-6.js
/www/luci-static/resources/view/network/vpn-0-7-0.js
/www/luci-static/resources/view/network/tailscale-0-7-5.js
/www/luci-static/resources/view/network/tailscale-0-7-4.js
/www/luci-static/resources/view/network/tailscale-0-7-0.js
/www/luci-static/resources/view/system/update-0-7-3.js
/www/luci-static/resources/view/system/update-0-7-2.js
/www/luci-static/resources/view/system/update-0-7-1.js
/www/luci-static/resources/view/system/update-0-7-0.js
/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js
/www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js
/www/luci-static/resources/view/network/vpn-0-6-0.js
/www/luci-static/resources/view/network/tailscale-0-6-0.js
/www/luci-static/resources/view/system/update-0-6-0.js
/www/luci-static/resources/view/network/vpn-0-5-2.js
/www/luci-static/resources/view/network/tailscale-0-5-2.js
/usr/share/luci/menu.d/luci-app-vpn-ui.json
/usr/share/rpcd/acl.d/luci-app-vpn-ui.json
/usr/share/vpn-ui/version
/etc/vpn-ui-update.conf
/etc/crontabs/root
/etc/xray/vless-profiles.d
/etc/xray/vless-selected
/etc/xray/direct-domains.txt
/etc/xray/direct-ips.txt
/etc/xray/vpn-ui-device-bypass-macs.txt
/etc/xray/exit-st-cf.json
/etc/init.d/xray-transparent
$GEOSITE_FILE"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_exit() {
  local rc="$?"
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ "$ROLLBACK_READY" = "1" ] && [ "$INSTALL_COMPLETE" != "1" ]; then
    printf 'Installation failed; automatically restoring %s\n' "$BACKUP_DIR" >&2
    sh "$ROLLBACK" >/tmp/vpn-ui-install-auto-rollback.log 2>&1 || true
  fi
  exit "$rc"
}
trap on_exit EXIT

download_file() {
  local url="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -T 120 -qO "$dst" "$url"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -T 120 -q -O "$dst" "$url"
  else
    die "curl, wget, or uclient-fetch is required to fetch VPN UI files from GitHub"
  fi
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

ensure_geosite_data() {
  local tmp bytes

  [ "$INSTALL_GEOSITE" = "1" ] || return 0
  if [ -s "$GEOSITE_FILE" ] && [ "$UPDATE_GEOSITE" != "1" ]; then
    printf 'Using existing Xray geosite data: %s\n' "$GEOSITE_FILE"
    return 0
  fi

  printf 'Installing Xray geosite data from %s\n' "$GEOSITE_URL"
  tmp="/tmp/vpn-ui-geosite-$TS.dat"
  rm -f "$tmp"
  download_file "$GEOSITE_URL" "$tmp"
  bytes="$(file_size "$tmp")"
  [ "$bytes" -ge "$GEOSITE_MIN_BYTES" ] ||
    die "downloaded geosite data is too small: $bytes bytes"

  mkdir -p "$(dirname "$GEOSITE_FILE")"
  mv "$tmp" "$GEOSITE_FILE"
  chmod 644 "$GEOSITE_FILE"
}

fetch_branch_files() {
  local dst="/tmp/luci-vpn-ui-files-$TS"
  local path

  rm -rf "$dst"
  mkdir -p "$dst"
  for path in \
    usr/sbin/vpn-ui \
    usr/sbin/vpn-ui-update \
    www/luci-static/resources/view/network/vpn.js \
    www/luci-static/resources/view/network/tailscale.js \
    www/luci-static/resources/view/system/update.js \
    www/luci-static/resources/view/status/include/35_vpn.js \
    usr/share/luci/menu.d/luci-app-vpn-ui.json \
    usr/share/rpcd/acl.d/luci-app-vpn-ui.json \
    usr/share/vpn-ui/version
  do
    download_file "${VPN_UI_RAW_BASE%/}/$path" "$dst/$path"
  done
  SRC_DIR="$dst"
}

ensure_source_files() {
  if [ -f "$SRC_DIR/usr/sbin/vpn-ui" ] &&
    [ -f "$SRC_DIR/usr/sbin/vpn-ui-update" ] &&
    [ -f "$SRC_DIR/www/luci-static/resources/view/network/vpn.js" ] &&
    [ -f "$SRC_DIR/www/luci-static/resources/view/network/tailscale.js" ] &&
    [ -f "$SRC_DIR/www/luci-static/resources/view/system/update.js" ] &&
    [ -f "$SRC_DIR/www/luci-static/resources/view/status/include/35_vpn.js" ] &&
    [ -f "$SRC_DIR/usr/share/luci/menu.d/luci-app-vpn-ui.json" ] &&
    [ -f "$SRC_DIR/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" ] &&
    [ -f "$SRC_DIR/usr/share/vpn-ui/version" ]; then
    return 0
  fi

  printf 'Fetching VPN UI files from %s\n' "$VPN_UI_RAW_BASE"
  fetch_branch_files
}

copy_file() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [ -f "$src" ] || die "missing installer file $src"
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  chmod "$mode" "$dst"
}

backup_path() {
  local path="$1"
  local target="$BACKUP_DIR/files$path"

  if [ -e "$path" ]; then
    mkdir -p "$(dirname "$target")"
    cp -pR "$path" "$target"
  else
    printf '%s\n' "$path" >> "$BACKUP_DIR/missing"
  fi
}

create_full_backup() {
  local checksum temporary bytes size_kb free_kb

  [ "$SKIP_SYSUPGRADE_BACKUP" = "1" ] && return 0
  command -v sysupgrade >/dev/null 2>&1 ||
    die "sysupgrade is required to create the mandatory pre-install backup"
  mkdir -p "$FULL_BACKUP_DIR"
  chmod 700 "$FULL_BACKUP_DIR"
  FULL_BACKUP="$FULL_BACKUP_DIR/openwrt-before-router-ui-${VERSION:-unknown}-$TS.tar.gz"
  printf 'Creating mandatory OpenWrt backup: %s\n' "$FULL_BACKUP"
  temporary="/tmp/openwrt-before-router-ui-${VERSION:-unknown}-$TS.tar.gz"
  rm -f "$temporary"
  sysupgrade -b "$temporary" >/tmp/vpn-ui-sysupgrade-backup.log 2>&1 || {
    rm -f "$temporary"
    die "could not create the mandatory OpenWrt backup"
  }
  [ -s "$temporary" ] || {
    rm -f "$temporary"
    die "OpenWrt backup is empty"
  }
  tar -tzf "$temporary" >/dev/null 2>&1 || {
    rm -f "$temporary"
    die "OpenWrt backup archive validation failed"
  }
  bytes="$(wc -c < "$temporary" | tr -d ' ')"
  size_kb=$(((bytes + 1023) / 1024))
  free_kb="$(df -Pk "$FULL_BACKUP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [ -n "$free_kb" ] && [ "$free_kb" -ge $((size_kb + 2048)) ] || {
    rm -f "$temporary"
    die "not enough persistent free space for the verified OpenWrt backup"
  }
  cp "$temporary" "$FULL_BACKUP" || {
    rm -f "$temporary" "$FULL_BACKUP"
    die "could not persist the verified OpenWrt backup"
  }
  rm -f "$temporary"
  tar -tzf "$FULL_BACKUP" >/dev/null 2>&1 || {
    rm -f "$FULL_BACKUP"
    die "persisted OpenWrt backup archive validation failed"
  }
  checksum="$(sha256sum "$FULL_BACKUP" | awk '{ print $1 }')"
  printf '%s  %s\n' "$checksum" "$(basename "$FULL_BACKUP")" > "$FULL_BACKUP.sha256"
  chmod 600 "$FULL_BACKUP" "$FULL_BACKUP.sha256"
}

ensure_source_files
[ -n "$VERSION" ] ||
  VERSION="$(sed -n '1p' "$SRC_DIR/usr/share/vpn-ui/version" 2>/dev/null | tr -d '\r\n' || true)"
create_full_backup

mkdir -p "$BACKUP_DIR/files"
: > "$BACKUP_DIR/missing"

printf '%s\n' "$TOUCHED_PATHS" | while IFS= read -r path; do
  [ -n "$path" ] || continue
  backup_path "$path"
done

cat > "$BACKUP_DIR/README" <<EOF
OpenWrt VPN UI preinstall backup.
Created: $TS

Rollback:
  sh $ROLLBACK
EOF

cat > "$ROLLBACK" <<EOF
#!/bin/ash
set -eu

BACKUP_DIR="$BACKUP_DIR"
TOUCHED_PATHS="$TOUCHED_PATHS"

restore_path() {
  local path="\$1"
  local source="\$BACKUP_DIR/files\$path"

  rm -rf "\$path"
  if [ -e "\$source" ]; then
    mkdir -p "\$(dirname "\$path")"
    cp -pR "\$source" "\$path"
  fi
}

printf '%s\n' "\$TOUCHED_PATHS" | while IFS= read -r path; do
  [ -n "\$path" ] || continue
  restore_path "\$path"
done

if [ -f "\$BACKUP_DIR/missing" ]; then
  while IFS= read -r path; do
    [ -n "\$path" ] || continue
    rm -rf "\$path"
  done < "\$BACKUP_DIR/missing"
fi

rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
/etc/init.d/rpcd restart >/tmp/vpn-ui-rollback-rpcd.log 2>&1 || true
/etc/init.d/uhttpd restart >/tmp/vpn-ui-rollback-uhttpd.log 2>&1 || true

if [ -f /etc/xray/exit-st-cf.json ]; then
  XRAY_BIN=""
  [ -x /usr/local/bin/xray-latest ] && XRAY_BIN="/usr/local/bin/xray-latest"
  [ -n "\$XRAY_BIN" ] || XRAY_BIN="\$(command -v xray 2>/dev/null || true)"
  if [ -n "\$XRAY_BIN" ]; then
    "\$XRAY_BIN" run -test -config /etc/xray/exit-st-cf.json >/tmp/vpn-ui-rollback-xray-test.log 2>&1 &&
      /etc/init.d/xray-exit-st restart >/tmp/vpn-ui-rollback-xray-restart.log 2>&1 || true
  fi
fi

[ -x /etc/init.d/xray-transparent ] &&
  /etc/init.d/xray-transparent restart >/tmp/vpn-ui-rollback-transparent.log 2>&1 || true

printf 'Rolled back VPN UI install from %s\n' "\$BACKUP_DIR"
EOF
chmod 700 "$ROLLBACK"
cp "$ROLLBACK" "$LATEST_ROLLBACK"
chmod 700 "$LATEST_ROLLBACK"
ROLLBACK_READY=1
if [ -n "$VPN_UI_ROLLBACK_MARKER" ]; then
  printf '%s\n' "$ROLLBACK" > "$VPN_UI_ROLLBACK_MARKER"
  chmod 600 "$VPN_UI_ROLLBACK_MARKER"
fi

copy_file "$SRC_DIR/usr/sbin/vpn-ui" /usr/sbin/vpn-ui 755
copy_file "$SRC_DIR/usr/sbin/vpn-ui-update" /usr/sbin/vpn-ui-update 755
copy_file "$SRC_DIR/www/luci-static/resources/view/network/vpn.js" /www/luci-static/resources/view/network/vpn.js 644
copy_file "$SRC_DIR/www/luci-static/resources/view/network/tailscale.js" /www/luci-static/resources/view/network/tailscale.js 644
copy_file "$SRC_DIR/www/luci-static/resources/view/system/update.js" /www/luci-static/resources/view/system/update.js 644
copy_file "$SRC_DIR/www/luci-static/resources/view/status/include/35_vpn.js" /www/luci-static/resources/view/status/include/35_vpn.js 644
rm -f /www/luci-static/resources/view/status/include/_35_vpn.js
rm -f /www/luci-static/resources/view/network/vpn-0-7-6.js
rm -f /www/luci-static/resources/view/network/vpn-0-7-0.js
rm -f /www/luci-static/resources/view/network/vpn-0-6-0.js
rm -f /www/luci-static/resources/view/network/tailscale-0-6-0.js
rm -f /www/luci-static/resources/view/network/tailscale-0-7-5.js
rm -f /www/luci-static/resources/view/network/tailscale-0-7-4.js
rm -f /www/luci-static/resources/view/network/tailscale-0-7-0.js
rm -f /www/luci-static/resources/view/system/update-0-7-3.js
rm -f /www/luci-static/resources/view/system/update-0-6-0.js
rm -f /www/luci-static/resources/view/system/update-0-7-0.js
rm -f /www/luci-static/resources/view/system/update-0-7-1.js
rm -f /www/luci-static/resources/view/system/update-0-7-2.js
rm -f /www/luci-static/resources/view/status/include/35_vpn-0-7-0.js
rm -f /www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js
rm -f /www/luci-static/resources/view/network/vpn-0-5-2.js
rm -f /www/luci-static/resources/view/network/tailscale-0-5-2.js
copy_file "$SRC_DIR/usr/share/luci/menu.d/luci-app-vpn-ui.json" /usr/share/luci/menu.d/luci-app-vpn-ui.json 644
copy_file "$SRC_DIR/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" /usr/share/rpcd/acl.d/luci-app-vpn-ui.json 644
copy_file "$SRC_DIR/usr/share/vpn-ui/version" /usr/share/vpn-ui/version 644
ensure_geosite_data

mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i '\|/usr/sbin/vpn-ui auto-tick|d' /etc/crontabs/root
printf '%s\n' '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' >> /etc/crontabs/root
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true
/usr/sbin/vpn-ui-update configure-cron >/tmp/vpn-ui-update-cron.log 2>&1 ||
  die "could not configure router software update scheduling"

INIT_OUT="$(/usr/sbin/vpn-ui init)"
printf '%s\n' "$INIT_OUT" > /tmp/vpn-ui-init.json
printf '%s\n' "$INIT_OUT" | grep -q '"ok":true' || {
  printf '%s\n' "$INIT_OUT" >&2
  die "vpn-ui init failed; rollback with sh $ROLLBACK"
}
/usr/sbin/vpn-ui check | grep -q '"ok":true' ||
  die "VPN validation failed after installation"
/usr/sbin/vpn-ui vpn-summary | grep -q '"ok":true' ||
  die "VPN status validation failed after installation"
grep -q '"path":[[:space:]]*"network/vpn"' /usr/share/luci/menu.d/luci-app-vpn-ui.json ||
  die "LuCI VPN menu validation failed"
grep -q '"path":[[:space:]]*"network/tailscale"' /usr/share/luci/menu.d/luci-app-vpn-ui.json ||
  die "LuCI Tailscale menu validation failed"
grep -q '"path":[[:space:]]*"system/update"' /usr/share/luci/menu.d/luci-app-vpn-ui.json ||
  die "LuCI Update menu validation failed"
[ -f /www/luci-static/resources/view/status/include/35_vpn.js ] ||
  die "LuCI VPN status include validation failed"
[ ! -e /www/luci-static/resources/view/status/include/_35_vpn.js ] ||
  die "duplicate LuCI VPN status include is still installed"

rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
/etc/init.d/rpcd restart >/tmp/vpn-ui-install-rpcd.log 2>&1 || true
/etc/init.d/uhttpd restart >/tmp/vpn-ui-install-uhttpd.log 2>&1 || true

tar -czf "$BACKUP_DIR.tar.gz" -C /root "$(basename "$BACKUP_DIR")" 2>/dev/null || true
INSTALL_COMPLETE=1

printf 'Installed VPN UI.\n'
if [ -n "$FULL_BACKUP" ]; then
  printf 'Full OpenWrt backup: %s\n' "$FULL_BACKUP"
fi
printf 'Rollback command: sh %s\n' "$ROLLBACK"
printf 'Latest rollback alias: sh %s\n' "$LATEST_ROLLBACK"
