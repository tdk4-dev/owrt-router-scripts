#!/bin/sh
set -eu

# Install the LuCI VPN panel onto an already running OpenWrt router.
#
# Defaults assume ~/.ssh/config contains:
#   Host owrt
#     User root
#
# Usage:
#   ./install-openwrt-vpn-ui.sh
#   ROUTER_HOST=owrt-ts ./install-openwrt-vpn-ui.sh
#
# Optional environment:
#   ROUTER_HOST=owrt              SSH host alias or root@host
#   REMOTE_DIR=/tmp/luci-vpn-ui   Router temp directory for upload
#   PANEL_SOURCE=github           github or local
#   GITHUB_REPO=tdk4-dev/owrt-router-scripts
#   GITHUB_BRANCH=codex/vpn-panel-installer
#   GITHUB_REF=refs/heads/...     Override raw GitHub ref path if needed
#   LOCAL_BACKUP_DIR=router-backups
#   MAKE_SYSUPGRADE_BACKUP=1      Set to 0 to skip full OpenWrt config backup
#   KEEP_REMOTE_DIR=0             Set to 1 to leave uploaded installer in /tmp

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PANEL_DIR="$SCRIPT_DIR/luci-vpn-ui"
ROUTER_HOST="${ROUTER_HOST:-owrt}"
PANEL_SOURCE="${PANEL_SOURCE:-github}"
GITHUB_REPO="${GITHUB_REPO:-tdk4-dev/owrt-router-scripts}"
GITHUB_BRANCH="${GITHUB_BRANCH:-codex/vpn-panel-installer}"
GITHUB_REF="${GITHUB_REF:-refs/heads/$GITHUB_BRANCH}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPT_DIR/router-backups}"
MAKE_SYSUPGRADE_BACKUP="${MAKE_SYSUPGRADE_BACKUP:-1}"
KEEP_REMOTE_DIR="${KEEP_REMOTE_DIR:-0}"

TS="$(date +%Y%m%d-%H%M%S)"
REMOTE_DIR="${REMOTE_DIR:-/tmp/luci-vpn-ui-install-$TS}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

remote_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

github_luci_raw_base() {
  printf 'https://raw.githubusercontent.com/%s/%s/luci-vpn-ui' "$GITHUB_REPO" "$GITHUB_REF"
}

ssh_router() {
  ssh "$ROUTER_HOST" "$@"
}

require_tools_and_source() {
  command -v ssh >/dev/null 2>&1 || die "ssh is required"

  case "$PANEL_SOURCE" in
    github)
      ;;
    local)
      [ -d "$PANEL_DIR/files" ] || die "missing $PANEL_DIR/files"
      [ -f "$PANEL_DIR/install.sh" ] || die "missing $PANEL_DIR/install.sh"
      [ -f "$PANEL_DIR/files/usr/sbin/vpn-ui" ] || die "missing vpn-ui helper"
      command -v tar >/dev/null 2>&1 || die "tar is required for PANEL_SOURCE=local"
      ;;
    *)
      die "PANEL_SOURCE must be github or local"
      ;;
  esac
}

validate_remote_dir() {
  case "$REMOTE_DIR" in
    /tmp/luci-vpn-ui|/tmp/luci-vpn-ui-install-*)
      ;;
    *)
      die "REMOTE_DIR must be /tmp/luci-vpn-ui or /tmp/luci-vpn-ui-install-*"
      ;;
  esac
}

preflight_router() {
  local fetch_check=""
  local tar_check=""

  if [ "$PANEL_SOURCE" = "github" ]; then
    fetch_check='command -v curl >/dev/null || command -v wget >/dev/null || command -v uclient-fetch >/dev/null'
  else
    tar_check='command -v tar >/dev/null'
  fi

  ssh_router "
    set -eu
    [ -f /etc/openwrt_release ]
    [ \"\$(id -u)\" = \"0\" ]
    command -v sysupgrade >/dev/null
    command -v xray >/dev/null || [ -x /usr/local/bin/xray-latest ]
    [ -d /www/luci-static/resources/view/network ]
    [ -d /usr/share/luci/menu.d ]
    [ -d /usr/share/rpcd/acl.d ]
    $tar_check
    $fetch_check
  " || die "router preflight failed; verify SSH root access and OpenWrt/LuCI/Xray installation"
}

make_sysupgrade_backup() {
  local backup_info remote_path remote_sum local_path local_sum

  [ "$MAKE_SYSUPGRADE_BACKUP" = "1" ] || return 0

  info "Creating OpenWrt sysupgrade backup on $ROUTER_HOST"
  backup_info="$(ssh_router '
    set -eu
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="/tmp/openwrt-backup-vpn-ui-$ts.tar.gz"
    sysupgrade -b "$backup" >/dev/null
    sum="$(sha256sum "$backup" | awk "{ print \$1 }")"
    printf "%s %s\n" "$backup" "$sum"
  ')"

  remote_path="$(printf '%s\n' "$backup_info" | awk '{ print $1 }')"
  remote_sum="$(printf '%s\n' "$backup_info" | awk '{ print $2 }')"
  [ -n "$remote_path" ] || die "router did not report backup path"
  [ -n "$remote_sum" ] || die "router did not report backup checksum"

  mkdir -p "$LOCAL_BACKUP_DIR"
  local_path="$LOCAL_BACKUP_DIR/$(basename "$remote_path")"

  info "Copying backup to $local_path"
  ssh_router "cat $(remote_quote "$remote_path")" > "$local_path"
  local_sum="$(sha256_file "$local_path")"
  [ "$local_sum" = "$remote_sum" ] ||
    die "backup checksum mismatch: router $remote_sum, local $local_sum"

  printf 'Full config backup: %s\n' "$local_path"
  printf 'Backup SHA-256:     %s\n' "$local_sum"
  printf 'Full restore command:\n'
  printf "  ssh %s 'cat > /tmp/%s && sysupgrade -r /tmp/%s' < %s\n" \
    "$ROUTER_HOST" "$(basename "$local_path")" "$(basename "$local_path")" "$local_path"
}

upload_and_install() {
  local quoted_remote_dir raw_base install_url raw_files_base

  quoted_remote_dir="$(remote_quote "$REMOTE_DIR")"

  if [ "$PANEL_SOURCE" = "local" ]; then
    info "Uploading local panel bundle to $ROUTER_HOST:$REMOTE_DIR"
    tar -C "$PANEL_DIR" -cf - . |
      ssh_router "set -eu; rm -rf $quoted_remote_dir; mkdir -p $quoted_remote_dir; tar -C $quoted_remote_dir -xf -; sh $quoted_remote_dir/install.sh"
  else
    raw_base="$(github_luci_raw_base)"
    install_url="$raw_base/install.sh"
    raw_files_base="$raw_base/files"
    info "Installing panel from GitHub branch $GITHUB_REPO@$GITHUB_BRANCH"
    ssh_router "set -eu
      rm -rf $quoted_remote_dir
      mkdir -p $quoted_remote_dir
      download_file() {
        url=\"\$1\"
        dst=\"\$2\"
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL \"\$url\" -o \"\$dst\"
        elif command -v wget >/dev/null 2>&1; then
          wget -qO \"\$dst\" \"\$url\"
        else
          uclient-fetch -q -O \"\$dst\" \"\$url\"
        fi
      }
      download_file $(remote_quote "$install_url") $quoted_remote_dir/install.sh
      chmod 700 $quoted_remote_dir/install.sh
      VPN_UI_REPO=$(remote_quote "$GITHUB_REPO") \
      VPN_UI_BRANCH=$(remote_quote "$GITHUB_BRANCH") \
      VPN_UI_REF=$(remote_quote "$GITHUB_REF") \
      VPN_UI_RAW_BASE=$(remote_quote "$raw_files_base") \
        sh $quoted_remote_dir/install.sh"
  fi

  if [ "$KEEP_REMOTE_DIR" != "1" ]; then
    ssh_router "rm -rf $quoted_remote_dir" || true
  fi
}

verify_install() {
  local lan_ip

  info "Validating installed panel"
  ssh_router '
    set -eu
    /usr/sbin/vpn-ui check
    /usr/sbin/vpn-ui status >/tmp/vpn-ui-status.json
    jsonfilter -i /tmp/vpn-ui-status.json \
      -e "selected=@.selected" \
      -e "xray=@.services.xray" \
      -e "transparent=@.services.transparent"
    grep -q "network/vpn" /usr/share/luci/menu.d/luci-app-vpn-ui.json
  '

  lan_ip="$(ssh_router 'uci -q get network.lan.ipaddr 2>/dev/null || printf "%s" "10.20.0.1"')"

  printf '\nVPN panel URL:\n'
  printf '  http://%s/cgi-bin/luci/admin/network/vpn\n' "$lan_ip"
  printf '\nUI rollback command:\n'
  printf "  ssh %s 'sh /root/rollback-vpn-ui.sh'\n" "$ROUTER_HOST"
}

require_tools_and_source
validate_remote_dir
preflight_router
make_sysupgrade_backup
upload_and_install
verify_install

printf '\nDone.\n'
