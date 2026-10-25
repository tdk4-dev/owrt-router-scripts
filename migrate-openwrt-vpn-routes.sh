#!/bin/ash
set -eu

# Migrate an already-configured OpenWrt/Xray router from hardcoded direct
# routing rules inside /etc/xray/*.json to editable plain-text route files plus
# the vpn-routes helper command.
#
# Run on the router as root:
#   sh /root/migrate-openwrt-vpn-routes.sh

SCRIPT_NAME="$(basename "$0")"
RENDERER="/usr/libexec/openwrt-vpn-routes-renderer.sh"
HELPER="/usr/sbin/vpn-routes"
VARS_FILE="/etc/xray/vpn-routes.vars"
DOMAINS_FILE="/etc/xray/direct-domains.txt"
IPS_FILE="/etc/xray/direct-ips.txt"

XRAY_CONFIG="${XRAY_CONFIG:-}"
XRAY_SERVICE="${XRAY_SERVICE:-}"
XRAY_BIN="${XRAY_BIN:-}"
LAN_IP="${LAN_IP:-}"
VPS_DOMAIN="${VPS_DOMAIN:-}"
VPS_IP="${VPS_IP:-}"
VPS_PORT="${VPS_PORT:-}"
VLESS_UUID="${VLESS_UUID:-}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
REALITY_SNI="${REALITY_SNI:-}"
REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-}"
REALITY_SPIDERX="${REALITY_SPIDERX:-}"
XRAY_DATADIR="${XRAY_DATADIR:-}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

service_enabled() {
  local service="$1"
  [ -x "/etc/init.d/$service" ] && /etc/init.d/"$service" enabled >/dev/null 2>&1
}

service_running() {
  local service="$1"
  [ -x "/etc/init.d/$service" ] && /etc/init.d/"$service" running >/dev/null 2>&1
}

capture_xray_runtime_state() {
  XRAY_WAS_ENABLED=false
  XRAY_WAS_RUNNING=false
  TRANSPARENT_WAS_ENABLED=false
  TRANSPARENT_WAS_RUNNING=false
  service_enabled "$XRAY_SERVICE" && XRAY_WAS_ENABLED=true
  service_running "$XRAY_SERVICE" && XRAY_WAS_RUNNING=true
  service_enabled xray-transparent && TRANSPARENT_WAS_ENABLED=true
  service_running xray-transparent && TRANSPARENT_WAS_RUNNING=true
}

verify_captured_xray_runtime_state() {
  if [ "$XRAY_WAS_ENABLED" = true ]; then service_enabled "$XRAY_SERVICE" || return 1
  elif service_enabled "$XRAY_SERVICE"; then return 1; fi
  if [ "$XRAY_WAS_RUNNING" = true ]; then service_running "$XRAY_SERVICE" || return 1
  elif service_running "$XRAY_SERVICE"; then return 1; fi
  if [ "$TRANSPARENT_WAS_ENABLED" = true ]; then service_enabled xray-transparent || return 1
  elif service_enabled xray-transparent; then return 1; fi
  if [ "$TRANSPARENT_WAS_RUNNING" = true ]; then service_running xray-transparent || return 1
  elif service_running xray-transparent; then return 1; fi
}

restore_captured_xray_runtime_state() {
  local failed=0
  if [ "$XRAY_WAS_RUNNING" = true ]; then
    /etc/init.d/"$XRAY_SERVICE" restart >/tmp/vpn-routes-xray-restore.log 2>&1 || failed=1
  else
    /etc/init.d/"$XRAY_SERVICE" stop >/tmp/vpn-routes-xray-restore.log 2>&1 || true
  fi
  if [ "$TRANSPARENT_WAS_RUNNING" = true ]; then
    /etc/init.d/xray-transparent restart >/tmp/vpn-routes-transparent-restore.log 2>&1 || failed=1
  else
    /etc/init.d/xray-transparent stop >/tmp/vpn-routes-transparent-restore.log 2>&1 || true
  fi
  verify_captured_xray_runtime_state || failed=1
  [ "$failed" = 0 ]
}

usage() {
  cat <<EOF
Usage:
  sh $SCRIPT_NAME

Run on the OpenWrt router as root. The script:
  - backs up existing Xray config and helper files
  - extracts old direct domain/IP rules into:
      $DOMAINS_FILE
      $IPS_FILE
  - installs:
      $HELPER
  - regenerates and tests Xray config before restarting services

Environment overrides are available if autodetection fails:
  XRAY_CONFIG=/etc/xray/exit-st-cf.json
  XRAY_SERVICE=xray
  XRAY_BIN=/usr/bin/xray
  LAN_IP=10.20.0.1
  VPS_DOMAIN=example.com
  VPS_IP=203.0.113.10
  VPS_PORT=443
  VLESS_UUID=...
  REALITY_PUBLIC_KEY=...
  REALITY_SHORT_ID=...
  REALITY_SNI=www.cloudflare.com
  REALITY_FINGERPRINT=firefox
  REALITY_SPIDERX=/
  XRAY_DATADIR=/usr/share/xray

Internal:
  sh $SCRIPT_NAME --apply
EOF
}

require_openwrt_root() {
  [ -f /etc/openwrt_release ] || die "run this on OpenWrt, not on your Mac/Linux workstation"
  [ "$(id -u)" = "0" ] || die "run as root"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_tail_from_file() {
  local file="$1"
  local item esc

  [ -f "$file" ] || return
  while IFS= read -r item || [ -n "$item" ]; do
    item="$(printf '%s' "$item" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$item" ] || continue
    esc="$(json_escape "$item")"
    printf ',\n          "%s"' "$esc"
  done < "$file"
}

json_list_from_file() {
  local file="$1"
  local item esc first=1

  [ -f "$file" ] || return
  while IFS= read -r item || [ -n "$item" ]; do
    item="$(printf '%s' "$item" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$item" ] || continue
    esc="$(json_escape "$item")"
    if [ "$first" = "1" ]; then
      printf '\n          "%s"' "$esc"
      first=0
    else
      printf ',\n          "%s"' "$esc"
    fi
  done < "$file"
}

file_has_rule_prefix() {
  local file="$1"
  local prefix="$2"
  local item

  [ -f "$file" ] || return 1
  while IFS= read -r item || [ -n "$item" ]; do
    item="$(printf '%s' "$item" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$item" ] || continue
    case "$item" in
      "$prefix"*) return 0 ;;
    esac
  done < "$file"
  return 1
}

ensure_domain_rule_data() {
  local file="$1"

  [ -n "$XRAY_DATADIR" ] || XRAY_DATADIR="/usr/share/xray"
  if file_has_rule_prefix "$file" "geosite:"; then
    [ -s "$XRAY_DATADIR/geosite.dat" ] ||
      die "geosite rules require $XRAY_DATADIR/geosite.dat; install or copy Xray geosite data, then apply routes again"
  fi
}

active_line_count() {
  local file="$1"
  [ -f "$file" ] || {
    echo 0
    return
  }
  sed -n '/^[[:space:]]*#/!{/^[[:space:]]*$/!p}' "$file" | wc -l | tr -d ' '
}

append_unique_line() {
  local file="$1"
  local item="$2"

  [ -n "$item" ] || return
  touch "$file"
  grep -qxF "$item" "$file" 2>/dev/null || echo "$item" >> "$file"
}

is_ipv4() {
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'
}

json_string_value() {
  local key="$1"
  local file="$2"
  sed -n 's/^[[:space:]]*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" |
    sed -n '1p' |
    sed 's/\\\\/\\/g; s/\\"/"/g'
}

json_vnext_string_value() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    /"vnext"[[:space:]]*:/ { seen=1 }
    seen && $0 ~ "\"" key "\"" {
      print
      exit
    }
  ' "$file" |
    sed -n 's/^[[:space:]]*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    sed 's/\\\\/\\/g; s/\\"/"/g'
}

json_vnext_number_value() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    /"vnext"[[:space:]]*:/ { seen=1 }
    seen && $0 ~ "\"" key "\"" {
      gsub(/[^0-9]/, "", $0)
      print
      exit
    }
  ' "$file"
}

detect_vps_ip_from_transparent() {
  [ -f /etc/init.d/xray-transparent ] || return
  sed -n \
    -e 's/^[[:space:]]*FIN0_IP=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}.*/\1/p' \
    -e 's/^[[:space:]]*VPS_IP=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}.*/\1/p' \
    /etc/init.d/xray-transparent |
    sed -n '1p'
}

detect_vps_ip_from_dns() {
  local host="$1"
  nslookup "$host" 2>/dev/null |
    awk '
      /^Address [0-9]+: [0-9]/ { print $3; exit }
      /^Address: [0-9]/ { print $2; exit }
    '
}

detect_xray_paths() {
  local uci_config init_config init_bin

  if [ -z "$XRAY_SERVICE" ]; then
    if [ -x /etc/init.d/xray-exit-st ] && /etc/init.d/xray-exit-st enabled >/dev/null 2>&1; then
      XRAY_SERVICE="xray-exit-st"
    else
      XRAY_SERVICE="xray"
    fi
  fi

  if [ -z "$XRAY_CONFIG" ] && [ -f /etc/init.d/xray-exit-st ]; then
    init_config="$(sed -n 's/.* run -config \([^ ]*\).*/\1/p' /etc/init.d/xray-exit-st | sed -n '1p')"
    [ -n "$init_config" ] && [ -f "$init_config" ] && XRAY_CONFIG="$init_config"
  fi

  if [ -z "$XRAY_CONFIG" ]; then
    uci_config="$(uci -q get xray.config.conffiles 2>/dev/null | awk '{print $1}')"
    [ -n "$uci_config" ] && [ -f "$uci_config" ] && XRAY_CONFIG="$uci_config"
  fi

  if [ -z "$XRAY_CONFIG" ]; then
    [ -f /etc/xray/exit-st-cf.json ] && XRAY_CONFIG="/etc/xray/exit-st-cf.json"
  fi
  if [ -z "$XRAY_CONFIG" ]; then
    [ -f /etc/xray/config.json ] && XRAY_CONFIG="/etc/xray/config.json"
  fi
  [ -n "$XRAY_CONFIG" ] && [ -f "$XRAY_CONFIG" ] ||
    die "could not find Xray config; pass XRAY_CONFIG=/path/to/config.json"

  if [ -z "$XRAY_BIN" ] && [ -f /etc/init.d/xray-exit-st ]; then
    init_bin="$(sed -n 's/.* command \([^ ]*xray[^ ]*\) run.*/\1/p' /etc/init.d/xray-exit-st | sed -n '1p')"
    [ -n "$init_bin" ] && [ -x "$init_bin" ] && XRAY_BIN="$init_bin"
  fi
  if [ -z "$XRAY_BIN" ] && command -v xray >/dev/null 2>&1; then
    XRAY_BIN="$(command -v xray)"
  fi
  if [ -z "$XRAY_BIN" ] && [ -x /usr/local/bin/xray-latest ]; then
    XRAY_BIN="/usr/local/bin/xray-latest"
  fi
  [ -n "$XRAY_BIN" ] && [ -x "$XRAY_BIN" ] ||
    die "could not find xray binary; pass XRAY_BIN=/path/to/xray"

  [ -n "$XRAY_DATADIR" ] || XRAY_DATADIR="$(uci -q get xray.config.datadir 2>/dev/null || true)"
  [ -n "$XRAY_DATADIR" ] || XRAY_DATADIR="/usr/share/xray"
}

infer_vars_from_config() {
  [ -n "$LAN_IP" ] || LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
  [ -n "$LAN_IP" ] || LAN_IP="$(json_string_value listen "$XRAY_CONFIG")"

  [ -n "$VPS_DOMAIN" ] || VPS_DOMAIN="$(json_vnext_string_value address "$XRAY_CONFIG")"
  [ -n "$VPS_PORT" ] || VPS_PORT="$(json_vnext_number_value port "$XRAY_CONFIG")"
  [ -n "$VLESS_UUID" ] || VLESS_UUID="$(json_string_value id "$XRAY_CONFIG")"
  [ -n "$REALITY_PUBLIC_KEY" ] || REALITY_PUBLIC_KEY="$(json_string_value publicKey "$XRAY_CONFIG")"
  [ -n "$REALITY_SHORT_ID" ] || REALITY_SHORT_ID="$(json_string_value shortId "$XRAY_CONFIG")"
  [ -n "$REALITY_SNI" ] || REALITY_SNI="$(json_string_value serverName "$XRAY_CONFIG")"
  [ -n "$REALITY_FINGERPRINT" ] || REALITY_FINGERPRINT="$(json_string_value fingerprint "$XRAY_CONFIG")"
  [ -n "$REALITY_SPIDERX" ] || REALITY_SPIDERX="$(json_string_value spiderX "$XRAY_CONFIG")"

  if [ -z "$VPS_IP" ]; then
    VPS_IP="$(detect_vps_ip_from_transparent || true)"
  fi
  if [ -z "$VPS_IP" ] && is_ipv4 "$VPS_DOMAIN"; then
    VPS_IP="$VPS_DOMAIN"
  fi
  if [ -z "$VPS_IP" ] && [ -n "$VPS_DOMAIN" ]; then
    VPS_IP="$(detect_vps_ip_from_dns "$VPS_DOMAIN" || true)"
  fi

  [ -n "$REALITY_FINGERPRINT" ] || REALITY_FINGERPRINT="firefox"
  [ -n "$REALITY_SPIDERX" ] || REALITY_SPIDERX="/"
}

require_vars() {
  local missing=""
  for name in LAN_IP VPS_DOMAIN VPS_IP VPS_PORT VLESS_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SNI REALITY_FINGERPRINT REALITY_SPIDERX; do
    eval "[ -n \"\${$name:-}\" ]" || missing="$missing $name"
  done
  [ -z "$missing" ] || die "could not autodetect:$missing. Re-run with these values as environment variables."
  is_ipv4 "$VPS_IP" || die "VPS_IP must be an IPv4 address; got '$VPS_IP'"
  printf '%s' "$VPS_PORT" | grep -Eq '^[0-9]+$' || die "VPS_PORT must be numeric; got '$VPS_PORT'"
}

extract_direct_array() {
  local key="$1"
  local file="$2"
  awk -v key="$key" '
    function reset() {
      in_array = 0
      waiting = 0
      count = 0
      delete vals
    }
    function value_from_line(line, s) {
      s = line
      sub(/^[^\"]*\"/, "", s)
      sub(/\".*$/, "", s)
      gsub(/\\\\/, "\\", s)
      gsub(/\\"/, "\"", s)
      return s
    }
    $0 ~ "\"" key "\"[[:space:]]*:[[:space:]]*\\[" {
      in_array = 1
      count = 0
      next
    }
    in_array && $0 ~ "\\]" {
      in_array = 0
      waiting = 1
      next
    }
    in_array {
      if ($0 ~ /\"/) {
        count++
        vals[count] = value_from_line($0)
      }
      next
    }
    waiting && $0 ~ /"outboundTag"[[:space:]]*:[[:space:]]*"direct"/ {
      for (i = 1; i <= count; i++) print vals[i]
      reset()
      next
    }
    waiting && $0 ~ /"outboundTag"[[:space:]]*:/ {
      reset()
      next
    }
  ' "$file" | awk 'NF && !seen[$0]++'
}

is_builtin_direct_ip() {
  local item="$1"
  case "$item" in
    0.0.0.0/8|10.0.0.0/8|100.64.0.0/10|127.0.0.0/8|169.254.0.0/16|172.16.0.0/12|192.168.0.0/16|224.0.0.0/4|240.0.0.0/4)
      return 0
      ;;
    "$VPS_IP"|"$VPS_IP/32")
      return 0
      ;;
  esac
  return 1
}

write_route_files_from_existing_config() {
  local tmp item

  mkdir -p /etc/xray

  if [ ! -f "$DOMAINS_FILE" ]; then
    info "Extracting existing direct domains to $DOMAINS_FILE"
    {
      echo "# One Xray domain matcher per line. Blank lines and # comments are ignored."
      echo "# Examples:"
      echo "#   example.ru"
      echo "#   regexp:^.*\\.example\\.ru$"
      extract_direct_array domain "$XRAY_CONFIG"
    } > "$DOMAINS_FILE"
  else
    info "Keeping existing $DOMAINS_FILE"
  fi

  if [ ! -f "$IPS_FILE" ]; then
    info "Extracting existing extra direct IPs to $IPS_FILE"
    tmp="/tmp/direct-ips.$$"
    extract_direct_array ip "$XRAY_CONFIG" > "$tmp"
    {
      echo "# Extra public IPv4/CIDR bypasses, one per line."
      echo "# Private ranges, Tailscale CGNAT, and the VPS IP are always bypassed."
      while IFS= read -r item || [ -n "$item" ]; do
        [ -n "$item" ] || continue
        is_builtin_direct_ip "$item" && continue
        echo "$item"
      done < "$tmp"
    } > "$IPS_FILE"
    rm -f "$tmp"
  else
    info "Keeping existing $IPS_FILE"
  fi

  [ "$(active_line_count "$DOMAINS_FILE")" -gt 0 ] ||
    die "$DOMAINS_FILE is empty after extraction; refusing to rewrite Xray config"
}

backup_current_files() {
  local ts name dir archive

  ts="$(date +%Y%m%d-%H%M%S)"
  name="vpn-routes-migration-backup-$ts"
  dir="/tmp/$name"
  archive="/root/$name.tgz"
  info "Backing up current files to $archive"

  mkdir -p "$dir/etc" "$dir/usr/sbin" "$dir/usr/libexec" "$dir/root/$name"
  cp -a /etc/config "$dir/etc/config" 2>/dev/null || true
  cp -a /etc/xray "$dir/etc/xray" 2>/dev/null || true
  mkdir -p "$dir/etc/init.d"
  cp -a /etc/init.d/xray* "$dir/etc/init.d/" 2>/dev/null || true
  cp -a /etc/init.d/tailscale "$dir/etc/init.d/" 2>/dev/null || true
  cp -a /etc/init.d/adguardhome "$dir/etc/init.d/" 2>/dev/null || true
  cp -a /etc/sysctl.d "$dir/etc/sysctl.d" 2>/dev/null || true
  cp -a "$HELPER" "$dir/usr/sbin/" 2>/dev/null || true
  cp -a "$RENDERER" "$dir/usr/libexec/" 2>/dev/null || true
  [ -e "$HELPER" ] || touch "$dir/root/$name/no-vpn-routes-helper-before"
  [ -e "$RENDERER" ] || touch "$dir/root/$name/no-vpn-routes-renderer-before"
  [ -e "$DOMAINS_FILE" ] || touch "$dir/root/$name/no-direct-domains-before"
  [ -e "$IPS_FILE" ] || touch "$dir/root/$name/no-direct-ips-before"
  [ -e "$VARS_FILE" ] || touch "$dir/root/$name/no-vpn-routes-vars-before"
  {
    for svc in xray xray-exit-st xray-transparent tailscale adguardhome network firewall dnsmasq; do
      [ -x "/etc/init.d/$svc" ] || continue
      enabled=0
      running=0
      service_enabled "$svc" && enabled=1
      service_running "$svc" && running=1
      printf '%s\t%s\t%s\n' "$svc" "$enabled" "$running"
    done
  } > "$dir/root/$name/service-state.tsv"
  if command -v sysupgrade >/dev/null 2>&1; then
    sysupgrade -b "$dir/root/$name/openwrt-sysupgrade-config-backup.tar.gz" >/dev/null 2>&1 || true
  fi
  {
    echo "DATE=$(date)"
    echo "XRAY_CONFIG=$XRAY_CONFIG"
    echo "XRAY_SERVICE=$XRAY_SERVICE"
    echo "XRAY_BIN=$XRAY_BIN"
    echo
    echo "== /etc/openwrt_release =="
    cat /etc/openwrt_release 2>/dev/null || true
    echo
    echo "== df =="
    df -hT 2>/dev/null || df -h 2>/dev/null || true
    echo
    echo "== ip addr =="
    ip addr 2>/dev/null || true
    echo
    echo "== ip route =="
    ip route 2>/dev/null || true
    echo
    echo "== ip rule =="
    ip rule show 2>/dev/null || true
    echo
    echo "== uci network =="
    uci show network 2>/dev/null || true
    echo
    echo "== uci dhcp =="
    uci show dhcp 2>/dev/null || true
    echo
    echo "== uci firewall =="
    uci show firewall 2>/dev/null || true
    echo
    echo "== uci xray =="
    uci show xray 2>/dev/null || true
    echo
    echo "== nft ruleset =="
    nft list ruleset 2>/dev/null || true
    echo
    echo "== service states =="
    for svc in xray xray-exit-st xray-transparent tailscale adguardhome dnsmasq firewall; do
      [ -x "/etc/init.d/$svc" ] || continue
      printf '%s enabled=' "$svc"
      /etc/init.d/"$svc" enabled >/dev/null 2>&1 && printf yes || printf no
      printf ' status='
      /etc/init.d/"$svc" status >/dev/null 2>&1 && printf running || printf unknown
      printf '\n'
    done
    echo
    echo "== current Xray config =="
    cat "$XRAY_CONFIG" 2>/dev/null || true
  } > "$dir/root/$name/state-dump.txt" 2>&1
  tar -czf "$archive" -C "$dir" . 2>/dev/null || true
  echo "$archive" > /root/LAST_VPN_ROUTES_MIGRATION_BACKUP
  write_rollback_script
  {
    echo "sh /root/rollback-vpn-routes-migration.sh"
    echo "sh /root/rollback-vpn-routes-migration.sh '$archive'"
  } > /root/LAST_VPN_ROUTES_MIGRATION_ROLLBACK_COMMAND
}

write_rollback_script() {
  cat > /root/rollback-vpn-routes-migration.sh <<'EOF'
#!/bin/ash
set -eu

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  if [ -f /root/LAST_VPN_ROUTES_MIGRATION_BACKUP ]; then
    ARCHIVE="$(cat /root/LAST_VPN_ROUTES_MIGRATION_BACKUP)"
  fi
fi

[ -n "$ARCHIVE" ] || {
  echo "ERROR: pass a backup archive path, or keep /root/LAST_VPN_ROUTES_MIGRATION_BACKUP" >&2
  exit 1
}
[ -f "$ARCHIVE" ] || {
  echo "ERROR: backup archive not found: $ARCHIVE" >&2
  exit 1
}
NAME="$(basename "$ARCHIVE")"
NAME="${NAME%.tgz}"
MARKERS="/root/$NAME"

echo "Rolling back from $ARCHIVE"
/etc/init.d/xray-transparent stop 2>/dev/null || true
/etc/init.d/xray stop 2>/dev/null || true
/etc/init.d/xray-exit-st stop 2>/dev/null || true

tar -xzf "$ARCHIVE" -C /

[ -f "$MARKERS/no-vpn-routes-helper-before" ] && rm -f /usr/sbin/vpn-routes
[ -f "$MARKERS/no-vpn-routes-renderer-before" ] && rm -f /usr/libexec/openwrt-vpn-routes-renderer.sh
[ -f "$MARKERS/no-direct-domains-before" ] && rm -f /etc/xray/direct-domains.txt
[ -f "$MARKERS/no-direct-ips-before" ] && rm -f /etc/xray/direct-ips.txt
[ -f "$MARKERS/no-vpn-routes-vars-before" ] && rm -f /etc/xray/vpn-routes.vars

chmod 755 /etc/init.d/xray* 2>/dev/null || true
chmod 755 /etc/init.d/tailscale 2>/dev/null || true
chmod 755 /etc/init.d/adguardhome 2>/dev/null || true
chmod 755 /usr/sbin/vpn-routes 2>/dev/null || true
chmod 700 /usr/libexec/openwrt-vpn-routes-renderer.sh 2>/dev/null || true

STATE="$MARKERS/service-state.tsv"
[ -f "$STATE" ] || {
  echo "ERROR: exact pre-migration service state is missing" >&2
  exit 1
}

restore_service() {
  service="$1"
  expected_enabled="$2"
  expected_running="$3"
  [ -x "/etc/init.d/$service" ] || return 1
  if [ "$expected_running" = 1 ]; then
    /etc/init.d/"$service" restart >/dev/null 2>&1 || /etc/init.d/"$service" start >/dev/null 2>&1 || return 1
    /etc/init.d/"$service" running >/dev/null 2>&1 || return 1
  else
    /etc/init.d/"$service" stop >/dev/null 2>&1 || true
    ! /etc/init.d/"$service" running >/dev/null 2>&1 || return 1
  fi
  if [ "$expected_enabled" = 1 ]; then
    /etc/init.d/"$service" enable >/dev/null 2>&1 || return 1
    /etc/init.d/"$service" enabled >/dev/null 2>&1 || return 1
  else
    /etc/init.d/"$service" disable >/dev/null 2>&1 || true
    ! /etc/init.d/"$service" enabled >/dev/null 2>&1 || return 1
  fi
}

failed=0
while IFS="$(printf '\t')" read -r service enabled running; do
  [ -n "$service" ] || continue
  restore_service "$service" "$enabled" "$running" || failed=1
done < "$STATE"
[ "$failed" = 0 ] || {
  echo "ERROR: files were restored but exact service pre-state could not be recovered" >&2
  exit 1
}

echo "Rollback applied; archived configuration and exact service runtime/reboot state restored."
EOF
  chmod 700 /root/rollback-vpn-routes-migration.sh
}

write_vars_file() {
  cat > "$VARS_FILE" <<EOF
XRAY_CONFIG=$(shell_quote "$XRAY_CONFIG")
XRAY_SERVICE=$(shell_quote "$XRAY_SERVICE")
XRAY_BIN=$(shell_quote "$XRAY_BIN")
LAN_IP=$(shell_quote "$LAN_IP")
VPS_DOMAIN=$(shell_quote "$VPS_DOMAIN")
VPS_IP=$(shell_quote "$VPS_IP")
VPS_PORT=$(shell_quote "$VPS_PORT")
VLESS_UUID=$(shell_quote "$VLESS_UUID")
REALITY_PUBLIC_KEY=$(shell_quote "$REALITY_PUBLIC_KEY")
REALITY_SHORT_ID=$(shell_quote "$REALITY_SHORT_ID")
REALITY_SNI=$(shell_quote "$REALITY_SNI")
REALITY_FINGERPRINT=$(shell_quote "$REALITY_FINGERPRINT")
REALITY_SPIDERX=$(shell_quote "$REALITY_SPIDERX")
XRAY_DATADIR=$(shell_quote "$XRAY_DATADIR")
EOF
  chmod 600 "$VARS_FILE"
}

write_xray_config() {
  local out="$1"
  local vps_domain_json sni_json fp_json pbk_json sid_json spx_json uuid_json
  local extra_direct_ip_json direct_domain_json

  vps_domain_json="$(json_escape "$VPS_DOMAIN")"
  sni_json="$(json_escape "$REALITY_SNI")"
  fp_json="$(json_escape "$REALITY_FINGERPRINT")"
  pbk_json="$(json_escape "$REALITY_PUBLIC_KEY")"
  sid_json="$(json_escape "$REALITY_SHORT_ID")"
  spx_json="$(json_escape "$REALITY_SPIDERX")"
  uuid_json="$(json_escape "$VLESS_UUID")"
  extra_direct_ip_json="$(json_tail_from_file "$IPS_FILE")"
  ensure_domain_rule_data "$DOMAINS_FILE"
  direct_domain_json="$(json_list_from_file "$DOMAINS_FILE")"

  cat > "$out" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/tmp/xray-access.log",
    "error": "/tmp/xray-error.log"
  },
  "dns": {
    "servers": ["1.1.1.1", "1.0.0.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "$LAN_IP",
      "port": 11808,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true},
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "tag": "http-in",
      "listen": "$LAN_IP",
      "port": 11809,
      "protocol": "http",
      "settings": {},
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      }
    },
    {
      "tag": "transparent-in",
      "listen": "0.0.0.0",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$vps_domain_json",
            "port": $VPS_PORT,
            "users": [
              {
                "id": "$uuid_json",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$sni_json",
          "fingerprint": "$fp_json",
          "publicKey": "$pbk_json",
          "shortId": "$sid_json",
          "spiderX": "$spx_json"
        },
        "tcpSettings": {}
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainMatcher": "hybrid",
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "224.0.0.0/4",
          "240.0.0.0/4",
          "$VPS_IP/32"$extra_direct_ip_json
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "ipify.org",
          "api.ipify.org",
          "api4.ipify.org",
          "checkip.amazonaws.com",
          "ifconfig.me",
          "2ip.ru"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [$direct_domain_json
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["socks-in", "http-in", "transparent-in"],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
}

restart_xray_services() {
  [ -x "/etc/init.d/$XRAY_SERVICE" ] || return 1
  [ -x /etc/init.d/xray-transparent ] || return 1
  if [ "$XRAY_WAS_RUNNING" = true ]; then
    /etc/init.d/"$XRAY_SERVICE" restart >/tmp/vpn-routes-xray-restart.log 2>&1 || return 1
  fi
  verify_captured_xray_runtime_state
}

apply_routes() {
  local tmp backup transaction failure=""

  require_openwrt_root
  [ -f "$VARS_FILE" ] || die "missing $VARS_FILE; run full migration first"
  . "$VARS_FILE"
  require_vars
  [ "$(active_line_count "$DOMAINS_FILE")" -gt 0 ] ||
    die "$DOMAINS_FILE has no active entries"

  tmp="/tmp/xray-routes-new.$$"
  backup="$XRAY_CONFIG.bak.vpn-routes.$(date +%Y%m%d-%H%M%S)"
  transaction="/tmp/vpn-routes-apply.$$"
  mkdir "$transaction" && chmod 700 "$transaction" || die "could not preserve the route-apply pre-state"
  cp -p "$XRAY_CONFIG" "$transaction/config.preimage" || die "could not preserve the Xray configuration preimage"
  capture_xray_runtime_state
  write_xray_config "$tmp"
  "$XRAY_BIN" run -test -config "$tmp"
  cp "$XRAY_CONFIG" "$backup" 2>/dev/null || true
  cp "$tmp" "$XRAY_CONFIG" || failure="could not install the validated Xray configuration"
  rm -f "$tmp"
  [ -n "$failure" ] || restart_xray_services || failure="Xray restart returned without the exact daemon, transparent-proxy, and reboot pre-state"
  if [ -n "$failure" ]; then
    cp -p "$transaction/config.preimage" "$XRAY_CONFIG" || die "$failure; configuration rollback failed and recovery is required"
    if restore_captured_xray_runtime_state && cmp -s "$transaction/config.preimage" "$XRAY_CONFIG"; then
      rm -rf "$transaction"
      die "$failure; exact configuration, daemon, transparent-proxy, and reboot pre-state restored"
    fi
    die "$failure; runtime rollback failed and recovery is required"
  fi
  rm -rf "$transaction"
  echo "VPN route rules applied. Backup: $backup"
}

install_helper() {
  mkdir -p /usr/libexec /usr/sbin
  cp "$0" "$RENDERER"
  chmod 700 "$RENDERER"
  cat > "$HELPER" <<'EOF'
#!/bin/ash
set -eu

DOMAINS="/etc/xray/direct-domains.txt"
IPS="/etc/xray/direct-ips.txt"
RENDERER="/usr/libexec/openwrt-vpn-routes-renderer.sh"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage:
  vpn-routes list
  vpn-routes add-domain DOMAIN_OR_MATCHER [...]
  vpn-routes del-domain DOMAIN_OR_MATCHER [...]
  vpn-routes add-ip IPV4_OR_CIDR [...]
  vpn-routes del-ip IPV4_OR_CIDR [...]
  vpn-routes edit domains
  vpn-routes edit ips
  vpn-routes apply

Examples:
  vpn-routes add-domain example.ru
  vpn-routes add-domain 'regexp:^.*\.example\.ru$'
  vpn-routes add-domain geosite:alibaba
  vpn-routes add-ip 203.0.113.10/32
USAGE
}

append_unique() {
  local file="$1"
  local item="$2"
  [ -n "$item" ] || return
  touch "$file"
  grep -qxF "$item" "$file" 2>/dev/null || echo "$item" >> "$file"
}

delete_exact() {
  local file="$1"
  local item="$2"
  local tmp="/tmp/vpn-routes.$$"
  [ -f "$file" ] || return
  grep -vxF "$item" "$file" > "$tmp" || true
  mv "$tmp" "$file"
}

apply_routes() {
  [ -f "$RENDERER" ] || die "missing $RENDERER"
  sh "$RENDERER" --apply
}

case "${1:-}" in
  list)
    echo "== direct domains =="
    sed -n '/^[[:space:]]*#/!{/^[[:space:]]*$/!p}' "$DOMAINS" 2>/dev/null || true
    echo
    echo "== extra direct IPs =="
    sed -n '/^[[:space:]]*#/!{/^[[:space:]]*$/!p}' "$IPS" 2>/dev/null || true
    ;;
  add-domain)
    shift
    [ "$#" -gt 0 ] || die "add-domain needs at least one value"
    for item in "$@"; do append_unique "$DOMAINS" "$item"; done
    apply_routes
    ;;
  del-domain)
    shift
    [ "$#" -gt 0 ] || die "del-domain needs at least one value"
    for item in "$@"; do delete_exact "$DOMAINS" "$item"; done
    apply_routes
    ;;
  add-ip)
    shift
    [ "$#" -gt 0 ] || die "add-ip needs at least one value"
    for item in "$@"; do append_unique "$IPS" "$item"; done
    apply_routes
    ;;
  del-ip)
    shift
    [ "$#" -gt 0 ] || die "del-ip needs at least one value"
    for item in "$@"; do delete_exact "$IPS" "$item"; done
    apply_routes
    ;;
  edit)
    case "${2:-}" in
      domains) ${EDITOR:-vi} "$DOMAINS" ;;
      ips) ${EDITOR:-vi} "$IPS" ;;
      *) die "use: vpn-routes edit domains|ips" ;;
    esac
    apply_routes
    ;;
  apply)
    apply_routes
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
EOF
  chmod 755 "$HELPER"
}

main_migrate() {
  require_openwrt_root
  detect_xray_paths
  infer_vars_from_config
  require_vars

  info "Detected config"
  printf 'Xray config:  %s\n' "$XRAY_CONFIG"
  printf 'Xray service: %s\n' "$XRAY_SERVICE"
  printf 'Xray binary:  %s\n' "$XRAY_BIN"
  printf 'LAN IP:       %s\n' "$LAN_IP"
  printf 'VPS:          %s:%s (bypass IP %s)\n' "$VPS_DOMAIN" "$VPS_PORT" "$VPS_IP"

  backup_current_files
  write_route_files_from_existing_config
  write_vars_file
  install_helper
  apply_routes

  cat <<EOF

Migration complete.

Edit direct VPN routes with:
  vpn-routes list
  vpn-routes add-domain example.ru
  vpn-routes add-domain 'regexp:^.*\\.example\\.ru$'
  vpn-routes edit domains
  vpn-routes add-ip 203.0.113.10/32
  vpn-routes apply

Files:
  $DOMAINS_FILE
  $IPS_FILE

Last migration backup:
  $(cat /root/LAST_VPN_ROUTES_MIGRATION_BACKUP 2>/dev/null || true)
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    ;;
  --apply)
    apply_routes
    ;;
  "")
    main_migrate
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
