#!/bin/ash
set -eu

# Run this script directly on an already-running OpenWrt router as root.
#
# Latest stable release:
#   sh install-router-ui-release.sh
#
# Pin a release:
#   ROUTER_UI_VERSION=0.8.0 sh install-router-ui-release.sh

REPO="${ROUTER_UI_REPO:-tdk4-dev/owrt-router-scripts}"
REQUESTED_VERSION="${ROUTER_UI_VERSION:-}"
TS="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="/tmp/router-ui-release-$TS"
BACKUP_DIR="/root/router-ui-backups"
LOG_FILE="/tmp/router-ui-release-install.log"
PACKAGES_FILE="router-ui-packages.txt"
MANIFEST_FILE="router-release-manifest.json"
LEGACY_BUNDLE="luci-vpn-ui.tar.gz"
PROJECT_PACKAGES="premier-router-core luci-app-premier-router premier-router-setup"
SKIP_BACKUP="${ROUTER_UI_SKIP_BACKUP:-0}"
EXISTING_BACKUP="${ROUTER_UI_EXISTING_BACKUP:-}"

LEGACY_PACKAGE_FILES="/usr/sbin/vpn-ui
/usr/sbin/vpn-ui-update
/usr/sbin/install-router-ui-release
/usr/sbin/router-prep
/usr/share/vpn-ui/version
/usr/share/vpn-ui/legacy-files.list
/usr/share/luci/menu.d/luci-app-vpn-ui.json
/usr/share/rpcd/acl.d/luci-app-vpn-ui.json
/www/luci-static/resources/view/network/vpn.js
/www/luci-static/resources/view/network/tailscale.js
/www/luci-static/resources/view/status/include/35_vpn.js
/www/luci-static/resources/view/status/include/_35_vpn.js
/www/luci-static/resources/view/system/update.js
/www/luci-static/resources/view/system/reset.js
/www/luci-static/resources/view/network/vpn-0-7-0.js
/www/luci-static/resources/view/network/tailscale-0-7-5.js
/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js
/www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js
/www/luci-static/resources/view/system/update-0-7-3.js
/www/luci-static/resources/view/system/reset-0-8-0.js
/www/luci-static/resources/view/network/vpn-0-6-0.js
/www/luci-static/resources/view/network/tailscale-0-6-0.js
/www/luci-static/resources/view/network/tailscale-0-7-0.js
/www/luci-static/resources/view/network/tailscale-0-7-4.js
/www/luci-static/resources/view/network/vpn-0-5-2.js
/www/luci-static/resources/view/network/tailscale-0-5-2.js
/www/luci-static/resources/view/system/update-0-6-0.js
/www/luci-static/resources/view/system/update-0-7-0.js
/www/luci-static/resources/view/system/update-0-7-1.js
/www/luci-static/resources/view/system/update-0-7-2.js
/etc/uci-defaults/99-openwrt-fin0-firstboot
/www/cgi-bin/firstboot-setup
/www/cgi-bin/router-prep
/www/setup/index.html
/www/setup/styles.css
/www/setup/app.js
/www/prepare/index.html
/www/prepare/styles.css
/www/prepare/app.js"

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
      curl -4 -fsSL --proto '=https' --connect-timeout 10 --max-time 120 "$url" -o "$dst" && return 0
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

package_installed() {
  opkg status "$1" 2>/dev/null | grep -q '^Status: .* installed'
}

detect_install_type() {
  if package_installed premier-router-core || package_installed luci-app-premier-router; then
    printf 'ipk'
  elif [ -e /usr/sbin/vpn-ui ] || [ -e /usr/share/vpn-ui/version ] ||
    [ -e /www/luci-static/resources/view/network/vpn-0-7-0.js ]; then
    printf 'legacy-tar'
  else
    printf 'clean'
  fi
}

create_full_backup() {
  local version="$1"
  local full_backup temp_backup bytes size_kb free_kb checksum

  full_backup="$BACKUP_DIR/openwrt-before-router-ui-$version-$TS.tar.gz"
  temp_backup="/tmp/openwrt-before-router-ui-$version-$TS.tar.gz"
  printf 'Creating mandatory full OpenWrt backup: %s\n' "$full_backup"
  rm -f "$temp_backup"
  sysupgrade -b "$temp_backup" >/tmp/router-ui-sysupgrade-backup.log 2>&1 || {
    rm -f "$temp_backup"
    die "could not create full OpenWrt backup"
  }
  [ -s "$temp_backup" ] || {
    rm -f "$temp_backup"
    die "full OpenWrt backup is empty"
  }
  tar -tzf "$temp_backup" >/dev/null 2>&1 || {
    rm -f "$temp_backup"
    die "full OpenWrt backup validation failed"
  }
  bytes="$(wc -c < "$temp_backup" | tr -d ' ')"
  size_kb=$(((bytes + 1023) / 1024))
  free_kb="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [ -n "$free_kb" ] && [ "$free_kb" -ge $((size_kb + 2048)) ] || {
    rm -f "$temp_backup"
    die "not enough persistent free space for the verified OpenWrt backup"
  }
  cp "$temp_backup" "$full_backup" || {
    rm -f "$temp_backup" "$full_backup"
    die "could not persist the verified OpenWrt backup"
  }
  rm -f "$temp_backup"
  tar -tzf "$full_backup" >/dev/null 2>&1 || {
    rm -f "$full_backup"
    die "persisted OpenWrt backup validation failed"
  }
  checksum="$(sha256sum "$full_backup" | awk '{ print $1 }')"
  printf '%s  %s\n' "$checksum" "$(basename "$full_backup")" > "$full_backup.sha256"
  chmod 600 "$full_backup" "$full_backup.sha256"
  printf '%s' "$full_backup"
}

backup_legacy_files() {
  local snapshot="$1"
  local path target
  mkdir -p "$snapshot/files"
  : > "$snapshot/removed-files"
  printf '%s\n' "$LEGACY_PACKAGE_FILES" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$path" ] || continue
    target="$snapshot/files$path"
    mkdir -p "$(dirname "$target")"
    cp -pR "$path" "$target"
    printf '%s\n' "$path" >> "$snapshot/removed-files"
  done
}

remove_legacy_files() {
  local path
  printf '%s\n' "$LEGACY_PACKAGE_FILES" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      /usr/sbin/vpn-ui|/usr/sbin/vpn-ui-update|/usr/sbin/install-router-ui-release|/usr/sbin/router-prep|/usr/share/vpn-ui/*|/usr/share/luci/menu.d/luci-app-vpn-ui.json|/usr/share/rpcd/acl.d/luci-app-vpn-ui.json|/etc/uci-defaults/99-openwrt-fin0-firstboot|/www/cgi-bin/firstboot-setup|/www/cgi-bin/router-prep|/www/setup/*|/www/prepare/*|/www/luci-static/resources/view/*)
        rm -f "$path"
        ;;
      *)
        printf 'Refusing to remove unexpected legacy path: %s\n' "$path" >&2
        return 1
        ;;
    esac
  done
}

restore_legacy_files() {
  local snapshot="$1"
  local path source
  [ -f "$snapshot/removed-files" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    source="$snapshot/files$path"
    [ -e "$source" ] || continue
    mkdir -p "$(dirname "$path")"
    cp -pR "$source" "$path"
  done < "$snapshot/removed-files"
}

rollback_ipk_install() {
  local snapshot="$1"
  printf 'Installation failed; removing project packages and restoring backed-up legacy files when available.\n' >&2
  opkg remove luci-app-premier-router premier-router-setup premier-router-core >>"$LOG_FILE" 2>&1 || true
  restore_legacy_files "$snapshot"
  rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
  /etc/init.d/rpcd restart >>"$LOG_FILE" 2>&1 || true
  /etc/init.d/uhttpd restart >>"$LOG_FILE" 2>&1 || true
}

validate_package_line() {
  local pkg="$1"
  local version="$2"
  local arch="$3"
  local sha="$4"
  local size="$5"
  local file="$6"

  case " $PROJECT_PACKAGES " in *" $pkg "*) ;; *) return 1 ;; esac
  [ -n "$version" ] && [ -n "$sha" ] && [ -n "$size" ] && [ -n "$file" ] || return 1
  [ "$arch" = "all" ] || return 1
  case "$file" in
    "$pkg"_*.ipk) ;;
    *) return 1 ;;
  esac
  printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s' "$size" | grep -Eq '^[0-9]+$' || return 1
}

download_and_verify_ipks() {
  local pkg version arch sha size file ipk actual actual_size
  : > "$WORK_DIR/install-order"
  while read -r pkg version arch sha size file; do
    [ -n "${pkg:-}" ] || continue
    validate_package_line "$pkg" "$version" "$arch" "$sha" "$size" "$file" ||
      die "invalid package metadata line for $pkg"
    [ "$version" = "$PACKAGE_VERSION" ] ||
      die "package $pkg version $version does not match expected $PACKAGE_VERSION"
    ipk="$WORK_DIR/$file"
    fetch "$RELEASE_BASE/$file" "$ipk" ||
      die "could not download package $file"
    actual="$(sha256sum "$ipk" | awk '{ print $1 }')"
    [ "$actual" = "$sha" ] || die "checksum mismatch for $file"
    actual_size="$(wc -c < "$ipk" | tr -d ' ')"
    [ "$actual_size" = "$size" ] || die "size mismatch for $file"
    printf '%s\n' "$ipk" >> "$WORK_DIR/install-order"
  done < "$WORK_DIR/$PACKAGES_FILE"
  grep -q 'premier-router-core_' "$WORK_DIR/install-order" ||
    die "release package set is missing premier-router-core"
  grep -q 'luci-app-premier-router_' "$WORK_DIR/install-order" ||
    die "release package set is missing luci-app-premier-router"
  grep -q 'premier-router-setup_' "$WORK_DIR/install-order" ||
    die "release package set is missing premier-router-setup"
}

install_ipks() {
  local ipk
  while IFS= read -r ipk; do
    [ -n "$ipk" ] || continue
    opkg install "$ipk" >>"$LOG_FILE" 2>&1 || return 1
  done < "$WORK_DIR/install-order"
}

validate_install() {
  local pkg
  [ "$(cat /usr/share/vpn-ui/version 2>/dev/null)" = "$APP_VERSION" ] || return 1
  for pkg in $PROJECT_PACKAGES; do
    package_installed "$pkg" || return 1
  done
  # A package-first install is valid before the owner adds a VLESS profile.
  # `vpn-ui check` intentionally reports that empty state as not working, so
  # validate the backend/status contract here instead of requiring live VPN.
  /usr/sbin/vpn-ui status 2>/dev/null | grep -q '"ok":true' || return 1
  /usr/sbin/vpn-ui tailscale-status 2>/dev/null | grep -q '"ok":true' || return 1
  /usr/sbin/vpn-ui footer-info 2>/dev/null | grep -q '"footer_label":"Router Scripts v' || return 1
  [ -f /www/luci-static/resources/view/network/vpn-0-7-0.js ] || return 1
  [ -f /www/luci-static/resources/view/network/tailscale-0-7-5.js ] || return 1
  [ -f /www/luci-static/resources/view/system/update-0-7-3.js ] || return 1
  [ -f /www/luci-static/resources/view/system/reset-0-8-0.js ] || return 1
  [ -f /www/cgi-bin/firstboot-setup ] || return 1
}

legacy_tarball_install() {
  local bundle checksum expected actual installer marker before_sum current_sum rollback
  marker="$WORK_DIR/rollback-marker"
  bundle="$WORK_DIR/$LEGACY_BUNDLE"
  checksum="$WORK_DIR/$LEGACY_BUNDLE.sha256"

  printf 'Package metadata is not available; using deprecated tar.gz installer fallback.\n' >&2
  fetch "$RELEASE_BASE/$LEGACY_BUNDLE" "$bundle" ||
    die "could not download legacy release bundle"
  fetch "$RELEASE_BASE/$LEGACY_BUNDLE.sha256" "$checksum" ||
    die "could not download legacy release checksum"
  expected="$(awk '{ print $1 }' "$checksum" | sed -n '1p')"
  actual="$(sha256sum "$bundle" | awk '{ print $1 }')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
    die "legacy release checksum verification failed"
  validate_archive_paths "$bundle" ||
    die "legacy release archive contains unsafe paths"
  tar -xzf "$bundle" -C "$WORK_DIR" ||
    die "could not extract legacy release"
  installer="$WORK_DIR/luci-vpn-ui/install.sh"
  [ -f "$installer" ] || die "legacy release is missing install.sh"
  before_sum=""
  [ ! -f /root/rollback-vpn-ui.sh ] ||
    before_sum="$(sha256sum /root/rollback-vpn-ui.sh | awk '{ print $1 }')"
  if ! VPN_UI_ROLLBACK_MARKER="$marker" SKIP_SYSUPGRADE_BACKUP=1 INSTALL_GEOSITE=1 UPDATE_GEOSITE=0 \
    sh "$installer" >"$LOG_FILE" 2>&1; then
    rollback=""
    [ -f "$marker" ] && rollback="$(sed -n '1p' "$marker")"
    if [ -z "$rollback" ] && [ -x /root/rollback-vpn-ui.sh ]; then
      current_sum="$(sha256sum /root/rollback-vpn-ui.sh 2>/dev/null | awk '{ print $1 }')"
      if [ -z "$before_sum" ] || [ "$before_sum" != "$current_sum" ]; then
        rollback="/root/rollback-vpn-ui.sh"
      fi
    fi
    [ -n "$rollback" ] && [ -x "$rollback" ] && sh "$rollback" >>"$LOG_FILE" 2>&1 || true
    die "legacy tar.gz installation failed safely; inspect $LOG_FILE"
  fi
}

[ "$(id -u)" = "0" ] || die "run this script as root on OpenWrt"
[ -f /etc/openwrt_release ] || die "this does not appear to be OpenWrt"
command -v sysupgrade >/dev/null 2>&1 || die "sysupgrade is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
command -v opkg >/dev/null 2>&1 || die "opkg is required"

mkdir -p "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$WORK_DIR" "$BACKUP_DIR"
: > "$LOG_FILE"

if [ -n "$REQUESTED_VERSION" ]; then
  RELEASE_BASE="https://github.com/$REPO/releases/download/vpn-panel-v$REQUESTED_VERSION"
else
  RELEASE_BASE="https://github.com/$REPO/releases/latest/download"
fi

printf 'Reading release metadata from %s\n' "$RELEASE_BASE"
fetch "$RELEASE_BASE/vpn-ui-version.txt" "$WORK_DIR/version" ||
  die "could not download release version"
APP_VERSION="$(sed -n '1p' "$WORK_DIR/version" | tr -d '\r\n')"
[ -n "$APP_VERSION" ] || die "release version is empty"
[ -z "$REQUESTED_VERSION" ] || [ "$APP_VERSION" = "$REQUESTED_VERSION" ] ||
  die "requested $REQUESTED_VERSION but release metadata reports $APP_VERSION"
PACKAGE_VERSION="${ROUTER_UI_PACKAGE_VERSION:-$APP_VERSION-1}"

if ! fetch "$RELEASE_BASE/$MANIFEST_FILE" "$WORK_DIR/$MANIFEST_FILE"; then
  legacy_tarball_install
  rm -rf "$WORK_DIR"
  printf '\nRouter UI %s installed through deprecated tar.gz fallback.\n' "$APP_VERSION"
  exit 0
fi

fetch "$RELEASE_BASE/$PACKAGES_FILE" "$WORK_DIR/$PACKAGES_FILE" ||
  die "release manifest exists but package list is missing"

if [ "$SKIP_BACKUP" = "1" ]; then
  FULL_BACKUP="$EXISTING_BACKUP"
  [ -n "$FULL_BACKUP" ] || FULL_BACKUP="backup-created-by-caller"
else
  FULL_BACKUP="$(create_full_backup "$APP_VERSION")"
fi
INSTALL_TYPE="$(detect_install_type)"
MIGRATION_SNAPSHOT="$BACKUP_DIR/router-ui-migration-$APP_VERSION-$TS"
mkdir -p "$MIGRATION_SNAPSHOT"
printf 'Detected installation type: %s\n' "$INSTALL_TYPE"
printf 'Migration snapshot: %s\n' "$MIGRATION_SNAPSHOT"

download_and_verify_ipks

if [ "$INSTALL_TYPE" = "legacy-tar" ]; then
  backup_legacy_files "$MIGRATION_SNAPSHOT"
  remove_legacy_files
fi

printf 'Installing Premier Router packages %s\n' "$PACKAGE_VERSION"
if ! install_ipks; then
  rollback_ipk_install "$MIGRATION_SNAPSHOT"
  die "package installation failed safely; inspect $LOG_FILE"
fi

if [ "$INSTALL_TYPE" = "legacy-tar" ] &&
  ! /usr/sbin/vpn-ui metadata-set legacy-migrated self-managed local-only 0 0 >>"$LOG_FILE" 2>&1; then
  rollback_ipk_install "$MIGRATION_SNAPSHOT"
  die "legacy metadata migration failed safely; inspect $LOG_FILE"
fi

if ! validate_install; then
  rollback_ipk_install "$MIGRATION_SNAPSHOT"
  die "post-install validation failed safely; inspect $LOG_FILE"
fi

if [ -f /usr/share/vpn-ui/legacy-files.list ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f "$path"
  done < /usr/share/vpn-ui/legacy-files.list
fi

rm -rf "$WORK_DIR"
printf '\nPremier Router %s installed and validated through opkg packages.\n' "$APP_VERSION"
printf 'Full backup: %s\n' "$FULL_BACKUP"
printf 'Migration snapshot: %s\n' "$MIGRATION_SNAPSHOT"
