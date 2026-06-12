#!/bin/ash
set -eu

# Router-side setup for a fresh OpenWrt 24.10.x x86/64 install.
# Copy this file to the router, run it as root from an OpenWrt shell, and
# answer the prompts. It configures:
#   - Dropbear SSH on port 22 with a root password and optional public key
#   - x86 router networking, DHCP, dnsmasq -> AdGuardHome, firewall4
#   - Xray VLESS TCP Reality transparent proxy with RU/service bypasses
#   - Tailscale/Headscale subnet routing and exit-node advertisement

SCRIPT_NAME="$(basename "$0")"

DEFAULT_HOSTNAME="${HOSTNAME:-openwrt-fin0}"
DEFAULT_LAN_IP="${LAN_IP:-10.20.0.1}"
DEFAULT_LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"
DEFAULT_LAN_CIDR="${LAN_CIDR:-10.20.0.0/24}"
DEFAULT_DHCP_START="${LAN_DHCP_START:-100}"
DEFAULT_DHCP_LIMIT="${LAN_DHCP_LIMIT:-150}"
DEFAULT_WAN_PROTO="${WAN_PROTO:-dhcp}"
DEFAULT_TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-openwrt-fin0}"
DEFAULT_TAILSCALE_LOGIN_SERVER="${TAILSCALE_LOGIN_SERVER:--}"
DEFAULT_ADGUARD_USER="${ADGUARD_USER:-root}"

LAN_IP=""
LAN_NETMASK=""
LAN_CIDR=""
LAN_DHCP_START=""
LAN_DHCP_LIMIT=""
HOSTNAME_VALUE=""
WAN_DEVICE=""
LAN_PORTS=""
WAN_PROTO=""
WAN_IP=""
WAN_NETMASK=""
WAN_GATEWAY=""
WAN_DNS=""
PPPOE_USER=""
PPPOE_PASSWORD=""
SSH_LOGIN=""
SSH_PASSWORD=""
SSH_PUBLIC_KEY=""
ADGUARD_USER=""
ADGUARD_PASSWORD=""
VLESS_URL="${VLESS_URL:-}"
VPS_DOMAIN="${VPS_DOMAIN:-}"
VPS_IP="${VPS_IP:-}"
VPS_PORT="${VPS_PORT:-443}"
VLESS_UUID="${VLESS_UUID:-}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-}"
REALITY_SHORT_ID="${REALITY_SHORT_ID:-}"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"
REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-firefox}"
REALITY_SPIDERX="${REALITY_SPIDERX:-/}"
EXTRA_DIRECT_IPS="${EXTRA_DIRECT_IPS:-}"
EXTRA_DIRECT_DOMAINS="${EXTRA_DIRECT_DOMAINS:-}"
TORRENT_DIRECT_CLIENTS="${TORRENT_DIRECT_CLIENTS:-}"
TORRENT_DIRECT_PORTS="${TORRENT_DIRECT_PORTS:-51413}"
LOCAL_DNS_OVERRIDES="${LOCAL_DNS_OVERRIDES:-}"
TAILSCALE_HOSTNAME=""
TAILSCALE_LOGIN_SERVER=""
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
RUN_TAILSCALE_UP="${RUN_TAILSCALE_UP:-1}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
OVERWRITE_ADGUARD="${OVERWRITE_ADGUARD:-1}"
BLOCK_QUIC="${BLOCK_QUIC:-0}"
ALLOW_LOW_SPACE="${ALLOW_LOW_SPACE:-0}"
MIN_FREE_MB="${MIN_FREE_MB:-250}"
XRAY_DATADIR="${XRAY_DATADIR:-/usr/share/xray}"
INSTALL_GEOSITE="${INSTALL_GEOSITE:-1}"
UPDATE_GEOSITE="${UPDATE_GEOSITE:-0}"
GEOSITE_URL="${GEOSITE_URL:-https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat}"
GEOSITE_MIN_BYTES="${GEOSITE_MIN_BYTES:-1048576}"

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

usage() {
  cat <<EOF
Usage:
  sh $SCRIPT_NAME

Run on the OpenWrt router itself as root. The script is interactive.

Optional environment variables:
  INSTALL_PACKAGES=0         Skip opkg install if packages are already present
  VLESS_URL='vless://...'    Pre-fill VLESS Reality settings from a 3x-ui link
  TAILSCALE_AUTHKEY='...'    Pre-fill a Tailscale/Headscale auth key
  RUN_TAILSCALE_UP=0         Configure service/firewall but do not login
  OVERWRITE_ADGUARD=0        Keep existing /etc/adguardhome.yaml
  BLOCK_QUIC=1               Reject UDP/443 from LAN/tailnet instead of TPROXY
  TORRENT_DIRECT_CLIENTS=...  LAN client IPs whose torrent port should bypass Xray
  TORRENT_DIRECT_PORTS=51413  TCP/UDP source ports to bypass for those clients
  ALLOW_LOW_SPACE=1          Continue even if rootfs free space is below 250 MB
  MIN_FREE_MB=250            Free-space threshold for package installation

OpenWrt uses root as the admin SSH login. The script asks for a login name
only to make that explicit; non-root admin users are not configured here.
EOF
}

require_openwrt_root() {
  [ -f /etc/openwrt_release ] || die "run this on OpenWrt, not on your Mac/Linux workstation"
  [ "$(id -u)" = "0" ] || die "run as root"
}

prompt() {
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local __prompt_value

  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$label" "$default_value" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r __prompt_value || __prompt_value=""
  [ -n "$__prompt_value" ] || __prompt_value="$default_value"
  eval "$var=\"\$__prompt_value\""
}

prompt_secret() {
  local var="$1"
  local label="$2"
  local __prompt_secret_value

  printf '%s: ' "$label" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r __prompt_secret_value || __prompt_secret_value=""
  stty echo 2>/dev/null || true
  printf '\n' >&2
  eval "$var=\"\$__prompt_secret_value\""
}

prompt_secret_confirm() {
  local var="$1"
  local label="$2"
  local first second

  while :; do
    prompt_secret first "$label"
    prompt_secret second "Confirm $label"
    [ -n "$first" ] || {
      warn "value cannot be empty"
      continue
    }
    [ "$first" = "$second" ] || {
      warn "values did not match"
      continue
    }
    eval "$var=\$first"
    return
  done
}

available_netdevs() {
  ip -o link show 2>/dev/null |
    awk -F': ' '{print $2}' |
    sed 's/@.*//' |
    grep -E '^(eth[0-9]+|enp[0-9].*|eno[0-9].*|ens[0-9].*|lan[0-9]+|wan)$' |
    sort -u
}

default_wan_device() {
  if available_netdevs | grep -qx 'eth0'; then
    printf 'eth0'
    return
  fi
  available_netdevs | sed -n '1p'
}

default_lan_ports() {
  local wan="$1"
  local ports=""
  local dev

  for dev in $(available_netdevs); do
    [ "$dev" = "$wan" ] && continue
    ports="$ports $dev"
  done
  ports="${ports# }"
  [ -n "$ports" ] || ports="eth1"
  printf '%s' "$ports"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

json_tail_from_words() {
  local words="$1"
  local item esc
  for item in $words; do
    [ -n "$item" ] || continue
    esc="$(json_escape "$item")"
    printf ',\n          "%s"' "$esc"
  done
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

  if file_has_rule_prefix "$file" "geosite:"; then
    [ -s "$XRAY_DATADIR/geosite.dat" ] ||
      die "geosite rules require $XRAY_DATADIR/geosite.dat; install or copy Xray geosite data, then apply routes again"
  fi
}

append_unique_line() {
  local file="$1"
  local item="$2"

  [ -n "$item" ] || return
  touch "$file"
  grep -qxF "$item" "$file" 2>/dev/null || echo "$item" >> "$file"
}

url_decode_min() {
  sed \
    -e 's/+/ /g' \
    -e 's/%2[Ff]/\//g' \
    -e 's/%3[Aa]/:/g' \
    -e 's/%3[Ff]/?/g' \
    -e 's/%23/#/g' \
    -e 's/%26/\&/g' \
    -e 's/%3[Dd]/=/g' \
    -e 's/%20/ /g'
}

qs_value() {
  local query="$1"
  local key="$2"
  printf '%s' "$query" |
    tr '&' '\n' |
    sed -n "s/^$key=//p" |
    sed -n '1p' |
    url_decode_min
}

parse_vless_url() {
  local url="$1"
  local nofrag body rest hostport query parsed

  [ -n "$url" ] || return 0
  case "$url" in
    vless://*) ;;
    *) die "VLESS_URL must start with vless://" ;;
  esac

  nofrag="${url%%#*}"
  body="${nofrag#vless://}"
  VLESS_UUID="${body%%@*}"
  rest="${body#*@}"
  hostport="${rest%%\?*}"
  query=""
  case "$rest" in
    *\?*) query="${rest#*\?}" ;;
  esac

  VPS_DOMAIN="${hostport%:*}"
  parsed="${hostport##*:}"
  [ "$parsed" != "$hostport" ] && VPS_PORT="$parsed"

  parsed="$(qs_value "$query" pbk)"
  [ -n "$parsed" ] && REALITY_PUBLIC_KEY="$parsed"
  parsed="$(qs_value "$query" sid)"
  [ -n "$parsed" ] && REALITY_SHORT_ID="$parsed"
  parsed="$(qs_value "$query" sni)"
  [ -n "$parsed" ] && REALITY_SNI="$parsed"
  parsed="$(qs_value "$query" fp)"
  [ -n "$parsed" ] && REALITY_FINGERPRINT="$parsed"
  parsed="$(qs_value "$query" spx)"
  [ -n "$parsed" ] && REALITY_SPIDERX="$parsed"
}

is_ipv4() {
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'
}

detect_vps_ip() {
  local host="$1"
  local found=""

  if is_ipv4 "$host"; then
    printf '%s' "$host"
    return
  fi

  found="$(nslookup "$host" 2>/dev/null |
    awk '
      /^Address [0-9]+: [0-9]/ { print $3; exit }
      /^Address: [0-9]/ { print $2; exit }
    ')"
  printf '%s' "$found"
}

validate_nonempty() {
  local name="$1"
  local value="$2"
  [ -n "$value" ] || die "$name is required"
}

validate_inputs() {
  validate_nonempty "LAN IP" "$LAN_IP"
  validate_nonempty "LAN CIDR" "$LAN_CIDR"
  validate_nonempty "WAN device" "$WAN_DEVICE"
  validate_nonempty "LAN ports" "$LAN_PORTS"
  validate_nonempty "VPS domain/host" "$VPS_DOMAIN"
  validate_nonempty "VPS IPv4" "$VPS_IP"
  validate_nonempty "VLESS UUID" "$VLESS_UUID"
  validate_nonempty "Reality public key" "$REALITY_PUBLIC_KEY"
  validate_nonempty "Reality short ID" "$REALITY_SHORT_ID"
  validate_nonempty "Reality SNI" "$REALITY_SNI"
  validate_nonempty "AdGuard user" "$ADGUARD_USER"
  validate_nonempty "Tailscale hostname" "$TAILSCALE_HOSTNAME"
  printf '%s' "$ADGUARD_USER" | grep -Eq '^[A-Za-z0-9_.-]+$' ||
    die "AdGuard user can contain only letters, numbers, dot, underscore, and dash"
  is_ipv4 "$VPS_IP" || die "VPS IPv4 must be an IPv4 address, not a Cloudflare/proxy hostname"
  printf '%s' "$VPS_PORT" | grep -Eq '^[0-9]+$' || die "VPS port must be numeric"
}

backup_configs() {
  local ts dir archive
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="/root/openwrt-x86-fin0-pre-setup-$ts"
  archive="$dir.tgz"

  info "Saving config backup to $archive"
  mkdir -p "$dir/etc"
  cp -a /etc/config "$dir/etc/config" 2>/dev/null || true
  cp -a /etc/xray "$dir/etc/xray" 2>/dev/null || true
  mkdir -p "$dir/etc/init.d"
  cp -a /etc/init.d/xray-transparent "$dir/etc/init.d/" 2>/dev/null || true
  cp -a /etc/init.d/xray-exit-st "$dir/etc/init.d/" 2>/dev/null || true
  cp -a /etc/adguardhome.yaml "$dir/etc/" 2>/dev/null || true
  cp -a /etc/dropbear "$dir/etc/dropbear" 2>/dev/null || true
  if [ -n "$XRAY_DATADIR" ] && [ -f "$XRAY_DATADIR/geosite.dat" ]; then
    mkdir -p "$dir$XRAY_DATADIR"
    cp -a "$XRAY_DATADIR/geosite.dat" "$dir$XRAY_DATADIR/geosite.dat" 2>/dev/null || true
  fi
  tar -czf "$archive" -C "$dir" . 2>/dev/null || true
  echo "$archive" > /root/LAST_OPENWRT_X86_FIN0_PRE_SETUP_BACKUP
}

check_package_space() {
  local free_mb

  [ "$INSTALL_PACKAGES" = "1" ] || return
  free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$free_mb" ] || return
  [ "$free_mb" -ge "$MIN_FREE_MB" ] && return
  [ "$ALLOW_LOW_SPACE" = "1" ] && {
    warn "root filesystem has only ${free_mb} MB free; continuing because ALLOW_LOW_SPACE=1"
    return
  }

  cat <<EOF >&2
ERROR: root filesystem has only ${free_mb} MB free.

Installing xray-core, tailscale, and adguardhome usually needs more room than
the stock x86 image has before rootfs expansion.

Expand the OpenWrt rootfs/overlay to the SSD first, reboot, then rerun:
  sh /root/$SCRIPT_NAME

Set ALLOW_LOW_SPACE=1 only if this image already includes the needed packages
or you intentionally want to risk a partial opkg install.
EOF
  exit 1
}

dropbear_section() {
  local section

  for section in $(uci show dropbear 2>/dev/null | sed -n "s/^\(dropbear\.[^=]*\)=dropbear.*/\1/p"); do
    printf '%s' "$section"
    return
  done
}

configure_ssh_first() {
  local section

  info "SSH admin setup"
  prompt SSH_LOGIN "SSH login user (OpenWrt admin is root)" "root"
  if [ "$SSH_LOGIN" != "root" ]; then
    warn "OpenWrt's built-in administrative SSH login is root; this script will configure root."
    SSH_LOGIN="root"
  fi
  prompt_secret_confirm SSH_PASSWORD "New root SSH password"
  prompt SSH_PUBLIC_KEY "Optional SSH public key to install for root" ""

  printf '%s\n%s\n' "$SSH_PASSWORD" "$SSH_PASSWORD" | passwd root >/dev/null

  section="$(dropbear_section)"
  if [ -z "$section" ]; then
    uci set dropbear.main='dropbear'
    section='dropbear.main'
  fi
  uci set "$section.enable=1"
  uci set "$section.PasswordAuth=on"
  uci set "$section.RootPasswordAuth=on"
  uci set "$section.Port=22"
  uci commit dropbear

  if [ -n "$SSH_PUBLIC_KEY" ]; then
    mkdir -p /root/.ssh /etc/dropbear
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys /etc/dropbear/authorized_keys
    grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys ||
      echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    grep -qxF "$SSH_PUBLIC_KEY" /etc/dropbear/authorized_keys ||
      echo "$SSH_PUBLIC_KEY" >> /etc/dropbear/authorized_keys
    chmod 600 /root/.ssh/authorized_keys /etc/dropbear/authorized_keys
  fi

  /etc/init.d/dropbear enable
  /etc/init.d/dropbear restart
}

prompt_remaining_config() {
  local devs default_wan default_lan detected_ip

  info "Network interfaces"
  devs="$(available_netdevs | tr '\n' ' ')"
  [ -n "$devs" ] && printf 'Detected Ethernet devices: %s\n' "$devs" >&2
  default_wan="$(default_wan_device)"
  prompt WAN_DEVICE "WAN device" "$default_wan"
  default_lan="$(default_lan_ports "$WAN_DEVICE")"
  prompt LAN_PORTS "LAN bridge ports, space-separated" "$default_lan"

  prompt HOSTNAME_VALUE "Router hostname" "$DEFAULT_HOSTNAME"
  prompt LAN_IP "LAN IPv4 address" "$DEFAULT_LAN_IP"
  prompt LAN_NETMASK "LAN netmask" "$DEFAULT_LAN_NETMASK"
  prompt LAN_CIDR "LAN CIDR for Tailscale route advertisement" "$DEFAULT_LAN_CIDR"
  prompt LAN_DHCP_START "DHCP start offset" "$DEFAULT_DHCP_START"
  prompt LAN_DHCP_LIMIT "DHCP lease count" "$DEFAULT_DHCP_LIMIT"

  prompt WAN_PROTO "WAN protocol: dhcp, static, or pppoe" "$DEFAULT_WAN_PROTO"
  case "$WAN_PROTO" in
    dhcp) ;;
    static)
      prompt WAN_IP "WAN static IPv4 address" "${WAN_IP:-192.168.1.29}"
      prompt WAN_NETMASK "WAN netmask" "${WAN_NETMASK:-255.255.255.0}"
      prompt WAN_GATEWAY "WAN gateway" "${WAN_GATEWAY:-192.168.1.1}"
      prompt WAN_DNS "WAN DNS servers, space-separated" "${WAN_DNS:-1.1.1.1 8.8.8.8}"
      ;;
    pppoe)
      prompt PPPOE_USER "PPPoE username" "${PPPOE_USER:-}"
      prompt_secret PPPOE_PASSWORD "PPPoE password"
      ;;
    *) die "WAN protocol must be dhcp, static, or pppoe" ;;
  esac

  info "Xray Reality"
  prompt VLESS_URL "Paste VLESS Reality URL, or leave blank to enter fields manually" "$VLESS_URL"
  parse_vless_url "$VLESS_URL"
  prompt VPS_DOMAIN "VPS Reality host/domain from the VLESS link" "$VPS_DOMAIN"
  detected_ip="$(detect_vps_ip "$VPS_DOMAIN")"
  [ -n "$VPS_IP" ] || VPS_IP="$detected_ip"
  prompt VPS_IP "VPS direct IPv4 address (must be DNS-only, not Cloudflare proxied)" "$VPS_IP"
  prompt VPS_PORT "VPS Reality port" "$VPS_PORT"
  prompt VLESS_UUID "VLESS client UUID" "$VLESS_UUID"
  prompt REALITY_PUBLIC_KEY "Reality public key" "$REALITY_PUBLIC_KEY"
  prompt REALITY_SHORT_ID "Reality short ID" "$REALITY_SHORT_ID"
  prompt REALITY_SNI "Reality SNI/serverName" "$REALITY_SNI"
  prompt REALITY_FINGERPRINT "Reality fingerprint" "$REALITY_FINGERPRINT"
  prompt REALITY_SPIDERX "Reality spiderX" "$REALITY_SPIDERX"
  prompt EXTRA_DIRECT_IPS "Extra direct IPv4/CIDRs for Xray/nft, space-separated" "$EXTRA_DIRECT_IPS"
  prompt EXTRA_DIRECT_DOMAINS "Extra direct domains for Xray, space-separated" "$EXTRA_DIRECT_DOMAINS"

  info "AdGuardHome"
  prompt ADGUARD_USER "AdGuard web UI user" "$DEFAULT_ADGUARD_USER"
  prompt_secret_confirm ADGUARD_PASSWORD "AdGuard web UI password"
  prompt LOCAL_DNS_OVERRIDES "Optional dnsmasq local rewrites domain=ip, space-separated" "$LOCAL_DNS_OVERRIDES"

  info "Tailscale / Headscale"
  prompt TAILSCALE_HOSTNAME "Tailscale node hostname" "$DEFAULT_TAILSCALE_HOSTNAME"
  prompt TAILSCALE_LOGIN_SERVER "Headscale login server, or '-' for official Tailscale" "$DEFAULT_TAILSCALE_LOGIN_SERVER"
  [ "$TAILSCALE_LOGIN_SERVER" = "-" ] && TAILSCALE_LOGIN_SERVER=""
  if [ "$RUN_TAILSCALE_UP" = "1" ] && [ -z "$TAILSCALE_AUTHKEY" ]; then
    prompt_secret TAILSCALE_AUTHKEY "Tailscale/Headscale auth key (blank to skip tailscale up)"
  fi
}

confirm_summary() {
  local continue_answer

  cat <<EOF

Configuration summary:
  SSH login:              root
  Hostname:               $HOSTNAME_VALUE
  LAN:                    $LAN_IP/$LAN_NETMASK ($LAN_CIDR), ports: $LAN_PORTS
  WAN:                    $WAN_PROTO on $WAN_DEVICE
  DNS:                    dnsmasq on :53 -> AdGuardHome on 127.0.0.1:5353
  Xray:                   $VPS_DOMAIN:$VPS_PORT via Reality, SOCKS $LAN_IP:11808, HTTP $LAN_IP:11809, TPROXY :12345
  Xray VPS bypass IP:     $VPS_IP/32
  Tailscale hostname:     $TAILSCALE_HOSTNAME
  Tailscale login server: ${TAILSCALE_LOGIN_SERVER:-official Tailscale}
  Packages install:       $INSTALL_PACKAGES

The script will restart network, firewall, dnsmasq, AdGuardHome, Xray, and Tailscale.
If you are connected over SSH and LAN/WAN settings change, the session can disconnect.
EOF

  prompt continue_answer "Continue" "yes"
  case "$continue_answer" in
    y|Y|yes|YES) ;;
    *) die "cancelled" ;;
  esac
}

remove_network_devices_named() {
  local name="$1"
  local section found

  while :; do
    found=""
    for section in $(uci show network | sed -n "s/^\(network\.[^=]*\)=device.*/\1/p"); do
      [ "$(uci -q get "$section.name" || true)" = "$name" ] || continue
      uci delete "$section" || true
      found="$section"
      break
    done
    [ -n "$found" ] || return
  done
}

zone_section() {
  local name="$1"
  local section

  for section in $(uci show firewall | sed -n "s/^\(firewall\.[^=]*\)=zone.*/\1/p"); do
    [ "$(uci -q get "$section.name" || true)" = "$name" ] || continue
    printf '%s' "$section"
    return
  done
}

ensure_zone() {
  local name="$1"
  local section

  section="$(zone_section "$name")"
  if [ -z "$section" ]; then
    uci add firewall zone >/dev/null
    section="firewall.@zone[-1]"
  fi
  uci set "$section.name=$name"
  printf '%s' "$section"
}

ensure_forwarding() {
  local src="$1"
  local dest="$2"
  local section found=""

  for section in $(uci show firewall | sed -n "s/^\(firewall\.[^=]*\)=forwarding.*/\1/p"); do
    [ "$(uci -q get "$section.src" || true)" = "$src" ] || continue
    [ "$(uci -q get "$section.dest" || true)" = "$dest" ] || continue
    found="$section"
    break
  done
  if [ -z "$found" ]; then
    uci add firewall forwarding >/dev/null
    found="firewall.@forwarding[-1]"
  fi
  uci set "$found.src=$src"
  uci set "$found.dest=$dest"
}

remove_forwardings_with_zone() {
  local zone="$1"
  local section src dest deleted

  while :; do
    deleted=0
    for section in $(uci show firewall | sed -n "s/^\(firewall\.[^=]*\)=forwarding.*/\1/p"); do
      src="$(uci -q get "$section.src" || true)"
      dest="$(uci -q get "$section.dest" || true)"
      if [ "$src" = "$zone" ] || [ "$dest" = "$zone" ]; then
        uci delete "$section" || true
        deleted=1
        break
      fi
    done
    [ "$deleted" = "1" ] || return
  done
}

configure_network_dhcp_firewall() {
  local port lan_zone wan_zone ts_zone rewrite domain ip dns

  info "Configuring base network, DHCP, DNS, and firewall"
  uci set system.@system[0].hostname="$HOSTNAME_VALUE"
  uci commit system
  echo "$HOSTNAME_VALUE" > /proc/sys/kernel/hostname 2>/dev/null || true

  remove_network_devices_named br-lan
  uci set network.br_lan='device'
  uci set network.br_lan.name='br-lan'
  uci set network.br_lan.type='bridge'
  uci -q delete network.br_lan.ports
  for port in $LAN_PORTS; do
    uci add_list network.br_lan.ports="$port"
  done

  uci set network.lan='interface'
  uci set network.lan.device='br-lan'
  uci set network.lan.proto='static'
  uci set network.lan.ipaddr="$LAN_IP"
  uci set network.lan.netmask="$LAN_NETMASK"
  uci set network.lan.ip6assign='0'

  uci set network.wan='interface'
  uci set network.wan.device="$WAN_DEVICE"
  case "$WAN_PROTO" in
    dhcp)
      uci set network.wan.proto='dhcp'
      uci -q delete network.wan.ipaddr
      uci -q delete network.wan.netmask
      uci -q delete network.wan.gateway
      uci -q delete network.wan.dns
      ;;
    static)
      uci set network.wan.proto='static'
      uci set network.wan.ipaddr="$WAN_IP"
      uci set network.wan.netmask="$WAN_NETMASK"
      uci set network.wan.gateway="$WAN_GATEWAY"
      uci -q delete network.wan.dns
      for dns in $WAN_DNS; do
        uci add_list network.wan.dns="$dns"
      done
      ;;
    pppoe)
      uci set network.wan.proto='pppoe'
      uci set network.wan.username="$PPPOE_USER"
      uci set network.wan.password="$PPPOE_PASSWORD"
      ;;
  esac
  uci -q delete network.wan6
  uci commit network

  uci set dhcp.@dnsmasq[0].domainneeded='1'
  uci set dhcp.@dnsmasq[0].boguspriv='1'
  uci set dhcp.@dnsmasq[0].localise_queries='1'
  uci set dhcp.@dnsmasq[0].rebind_protection='1'
  uci set dhcp.@dnsmasq[0].rebind_localhost='1'
  uci set dhcp.@dnsmasq[0].local='/lan/'
  uci set dhcp.@dnsmasq[0].domain='lan'
  uci set dhcp.@dnsmasq[0].expandhosts='1'
  uci set dhcp.@dnsmasq[0].authoritative='1'
  uci set dhcp.@dnsmasq[0].localservice='0'
  # Keep temporary public DNS until AdGuardHome is installed and listening.
  uci set dhcp.@dnsmasq[0].noresolv='1'
  uci -q delete dhcp.@dnsmasq[0].server
  uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
  uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
  uci -q delete dhcp.@dnsmasq[0].address
  for rewrite in $LOCAL_DNS_OVERRIDES; do
    domain="${rewrite%%=*}"
    ip="${rewrite#*=}"
    [ -n "$domain" ] && [ -n "$ip" ] && [ "$domain" != "$ip" ] ||
      die "bad local DNS rewrite '$rewrite'; use domain=ip"
    uci add_list dhcp.@dnsmasq[0].address="/$domain/$ip"
  done

  uci set dhcp.lan='dhcp'
  uci set dhcp.lan.interface='lan'
  uci set dhcp.lan.start="$LAN_DHCP_START"
  uci set dhcp.lan.limit="$LAN_DHCP_LIMIT"
  uci set dhcp.lan.leasetime='12h'
  uci set dhcp.lan.dhcpv4='server'
  uci set dhcp.lan.dhcpv6='disabled'
  uci set dhcp.lan.ra='disabled'
  uci set dhcp.lan.ndp='disabled'
  uci set dhcp.lan.force='1'
  uci -q delete dhcp.lan.dhcp_option
  uci add_list dhcp.lan.dhcp_option="3,$LAN_IP"
  uci add_list dhcp.lan.dhcp_option="6,$LAN_IP"
  uci set dhcp.wan='dhcp'
  uci set dhcp.wan.interface='wan'
  uci set dhcp.wan.ignore='1'
  uci commit dhcp

  /etc/init.d/odhcpd disable 2>/dev/null || true
  /etc/init.d/odhcpd stop 2>/dev/null || true

  uci set firewall.@defaults[0].syn_flood='1'
  uci set firewall.@defaults[0].input='REJECT'
  uci set firewall.@defaults[0].output='ACCEPT'
  uci set firewall.@defaults[0].forward='REJECT'
  uci set firewall.@defaults[0].flow_offloading='0'
  uci set firewall.@defaults[0].flow_offloading_hw='0'

  lan_zone="$(ensure_zone lan)"
  uci set "$lan_zone.network=lan"
  uci set "$lan_zone.input=ACCEPT"
  uci set "$lan_zone.output=ACCEPT"
  uci set "$lan_zone.forward=ACCEPT"

  wan_zone="$(ensure_zone wan)"
  uci set "$wan_zone.network=wan"
  uci add_list "$wan_zone.network=wan6" 2>/dev/null || true
  uci set "$wan_zone.input=REJECT"
  uci set "$wan_zone.output=ACCEPT"
  uci set "$wan_zone.forward=REJECT"
  uci set "$wan_zone.masq=1"
  uci set "$wan_zone.mtu_fix=1"

  ensure_forwarding lan wan

  uci -q delete network.tailscale
  uci set network.tailscale='interface'
  uci set network.tailscale.proto='none'
  uci set network.tailscale.device='tailscale0'

  remove_forwardings_with_zone tailscale
  ts_zone="$(zone_section tailscale)"
  [ -n "$ts_zone" ] && uci delete "$ts_zone" || true
  ts_zone="$(ensure_zone tailscale)"
  uci set "$ts_zone.network=tailscale"
  uci set "$ts_zone.input=ACCEPT"
  uci set "$ts_zone.output=ACCEPT"
  uci set "$ts_zone.forward=REJECT"
  uci set "$ts_zone.mtu_fix=1"
  uci set "$ts_zone.masq=0"
  ensure_forwarding tailscale lan
  ensure_forwarding lan tailscale

  uci -q delete firewall.allow_xray_socks_lan
  uci set firewall.allow_xray_socks_lan='rule'
  uci set firewall.allow_xray_socks_lan.name='Allow-Xray-SOCKS-from-LAN'
  uci set firewall.allow_xray_socks_lan.src='lan'
  uci set firewall.allow_xray_socks_lan.proto='tcp'
  uci set firewall.allow_xray_socks_lan.dest_port='11808'
  uci set firewall.allow_xray_socks_lan.target='ACCEPT'

  uci -q delete firewall.allow_xray_http_lan
  uci set firewall.allow_xray_http_lan='rule'
  uci set firewall.allow_xray_http_lan.name='Allow-Xray-HTTP-from-LAN'
  uci set firewall.allow_xray_http_lan.src='lan'
  uci set firewall.allow_xray_http_lan.proto='tcp'
  uci set firewall.allow_xray_http_lan.dest_port='11809'
  uci set firewall.allow_xray_http_lan.target='ACCEPT'

  uci commit network
  uci commit firewall

  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-openwrt-fin0-routing.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=0
EOF
  sysctl -p /etc/sysctl.d/99-openwrt-fin0-routing.conf >/dev/null 2>&1 || true

  /etc/init.d/network reload || true
  /etc/init.d/firewall restart
  /etc/init.d/dnsmasq restart || true
}

install_packages() {
  if [ "$INSTALL_PACKAGES" != "1" ]; then
    info "Skipping opkg install because INSTALL_PACKAGES=$INSTALL_PACKAGES"
    return
  fi

  info "Installing packages"
  opkg update
  opkg install \
    ca-bundle \
    curl \
    kmod-tun \
    kmod-nft-tproxy \
    nftables-json \
    xray-core \
    tailscale \
    adguardhome
}

download_file() {
  local url="$1"
  local dst="$2"

  mkdir -p "$(dirname "$dst")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dst"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dst" "$url"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$dst" "$url"
  else
    die "curl, wget, or uclient-fetch is required to install Xray geosite data"
  fi
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

install_geosite_data() {
  local geosite_file tmp bytes

  [ "$INSTALL_GEOSITE" = "1" ] || return 0
  geosite_file="$XRAY_DATADIR/geosite.dat"
  if [ -s "$geosite_file" ] && [ "$UPDATE_GEOSITE" != "1" ]; then
    info "Using existing Xray geosite data at $geosite_file"
    return 0
  fi

  info "Installing Xray geosite data"
  mkdir -p "$XRAY_DATADIR"
  tmp="/tmp/openwrt-fin0-geosite.$$"
  rm -f "$tmp"
  download_file "$GEOSITE_URL" "$tmp"
  bytes="$(file_size "$tmp")"
  [ "$bytes" -ge "$GEOSITE_MIN_BYTES" ] ||
    die "downloaded geosite data is too small: $bytes bytes"
  mv "$tmp" "$geosite_file"
  chmod 644 "$geosite_file"
}

wait_for_http() {
  local url="$1"
  local i
  for i in $(seq 1 30); do
    if curl -fsS --connect-timeout 2 --max-time 4 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

extract_adguard_hash() {
  sed -n 's/^[[:space:]]*password:[[:space:]]*//p' /etc/adguardhome.yaml | sed -n '1p'
}

write_adguard_config() {
  local password_hash="$1"

  cat > /etc/adguardhome.yaml <<EOF
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:3000
  session_ttl: 720h
users:
  - name: $ADGUARD_USER
    password: $password_hash
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 5353
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://dns10.quad9.net/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 2160h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard DNS Popup Hosts filter
    id: 1779019548
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt
    name: HaGeZi's Ultimate Blocklist
    id: 1779019549
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /tmp/lib/adguardhome/userfilters/*
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 29
EOF
}

configure_adguard() {
  local user_json password_json payload password_hash

  info "Configuring AdGuardHome"
  /etc/init.d/adguardhome stop 2>/dev/null || true

  if [ -f /etc/adguardhome.yaml ] && [ "$OVERWRITE_ADGUARD" != "1" ]; then
    warn "keeping existing /etc/adguardhome.yaml because OVERWRITE_ADGUARD=$OVERWRITE_ADGUARD"
    /etc/init.d/adguardhome enable
    /etc/init.d/adguardhome restart
    return
  fi

  [ -f /etc/adguardhome.yaml ] &&
    cp /etc/adguardhome.yaml "/etc/adguardhome.yaml.bak.$(date +%Y%m%d-%H%M%S)"
  rm -f /etc/adguardhome.yaml

  /etc/init.d/adguardhome enable
  /etc/init.d/adguardhome start
  wait_for_http "http://127.0.0.1:3000/" ||
    die "AdGuardHome setup UI did not start on 127.0.0.1:3000"

  user_json="$(json_escape "$ADGUARD_USER")"
  password_json="$(json_escape "$ADGUARD_PASSWORD")"
  payload="{\"web\":{\"ip\":\"0.0.0.0\",\"port\":3000},\"dns\":{\"ip\":\"0.0.0.0\",\"port\":5353},\"username\":\"$user_json\",\"password\":\"$password_json\"}"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$payload" \
    http://127.0.0.1:3000/control/install/configure >/dev/null ||
    die "AdGuardHome install API failed"

  sleep 2
  /etc/init.d/adguardhome stop 2>/dev/null || true
  password_hash="$(extract_adguard_hash)"
  [ -n "$password_hash" ] || die "could not extract AdGuardHome password hash"
  write_adguard_config "$password_hash"
  chmod 600 /etc/adguardhome.yaml
  AdGuardHome --check-config -c /etc/adguardhome.yaml -w /var/lib/adguardhome >/dev/null
  uci set dhcp.@dnsmasq[0].noresolv='1'
  uci -q delete dhcp.@dnsmasq[0].server
  uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
  uci commit dhcp
  /etc/init.d/adguardhome restart
  /etc/init.d/dnsmasq restart
}

write_xray_route_files() {
  local item

  mkdir -p /etc/xray

  if [ ! -f /etc/xray/direct-domains.txt ]; then
    cat > /etc/xray/direct-domains.txt <<'EOF'
# One Xray domain matcher per line. Blank lines and # comments are ignored.
# Examples:
#   example.ru
#   regexp:^.*\.example\.ru$
#   geosite:alibaba
regexp:^.*\.ru$
regexp:^.*\.su$
regexp:^.*\.xn--p1ai$
government.ru
gov.ru
gosuslugi.ru
www.gosuslugi.ru
lk.gosuslugi.ru
esia.gosuslugi.ru
id.gosuslugi.ru
epgu.gosuslugi.ru
pos.gosuslugi.ru
gu-st.ru
regexp:^.*\.gosuslugi\.ru$
regexp:^.*\.gu-st\.ru$
emias.info
regexp:^.*\.emias\.info$
emias.ru
regexp:^.*\.emias\.ru$
emias.mos.ru
lk.emias.mos.ru
ap.emias.mos.ru
ap-emias.mos.ru
regexp:^.*\.emias\.mos\.ru$
mos.ru
login.mos.ru
my.mos.ru
lk.mos.ru
regexp:^.*\.mos\.ru$
mosgorzdrav.ru
regexp:^.*\.mosgorzdrav\.ru$
mosmedzdrav.ru
regexp:^.*\.mosmedzdrav\.ru$
gostelemed.ru
regexp:^.*\.gostelemed\.ru$
dr-telemed.ru
regexp:^.*\.dr-telemed\.ru$
nalog.ru
cbr.ru
moex.com
mosreg.ru
spb.ru
kremlin.ru
mil.ru
sberbank.ru
sbermarket.ru
sbermegamarket.ru
tbank-online.com
tinkoff.ru
cdn-tinkoff.ru
alfa-bank.com
alfa-bank.ru
alfabank.com
alfabank.ru
vtb.com
vtb.ru
vtb24.ru
gazprombank.ru
gpb.ru
psbank.ru
rshb.ru
nspk.ru
yandex
ya.ru
yandex.ru
yandex.com
yandex.net
yandex.cloud
yandex-team.ru
yastatic.net
yastat.net
yandexadexchange.net
vk.com
vk.ru
vk.me
vk.cc
vk-cdn.net
vk-cdn.me
vkuser.net
userapi.com
mail.ru
ok.ru
okcdn.ru
dzen.ru
rutube.ru
rutubelist.ru
avito.ru
www.avito.ru
m.avito.ru
api.avito.ru
pro-api.avito.ru
static.avito.ru
regexp:^.*\.avito\.ru$
avito.st
www.avito.st
regexp:^.*\.avito\.st$
ozon.ru
ozone.ru
ozonusercontent.com
wildberries.ru
wb.ru
dns-shop.ru
market.yandex.ru
megamarket.ru
magnit.ru
vkusvill.ru
5ka.ru
perekrestok.ru
dixy.ru
2gis.ru
2gis.com
2gis.kz
2gis.uz
auto.ru
hh.ru
banki.ru
rbc.ru
kommersant.ru
kp.ru
gazeta.ru
iz.ru
mts.ru
mymts.ru
megafon.ru
beeline.ru
tele2.ru
t2.ru
yota.ru
rostelecom.ru
rt.ru
rzd.ru
rzd-bonus.ru
aeroflot.ru
domclick.ru
dom.ru
pochta.ru
kaspersky.ru
kaspersky.com
drweb.ru
1c.ru
1cfresh.com
bitrix24.ru
timeweb.cloud
timeweb.com
fastvps.ru
boosty.to
donationalerts.com
okko.tv
okko.sport
kinopoisk.ru
clstorage.net
static-storage.net
EOF
  fi

  if [ ! -f /etc/xray/direct-ips.txt ]; then
    cat > /etc/xray/direct-ips.txt <<'EOF'
# Extra public IPv4/CIDR bypasses, one per line.
# Private ranges, Tailscale CGNAT, and the VPS IP are always bypassed.
EOF
  fi

  for item in $EXTRA_DIRECT_DOMAINS; do
    append_unique_line /etc/xray/direct-domains.txt "$item"
  done
  for item in $EXTRA_DIRECT_IPS; do
    append_unique_line /etc/xray/direct-ips.txt "$item"
  done
}

write_xray_vars() {
  mkdir -p /etc/xray
  cat > /etc/xray/exit-st-cf.vars <<EOF
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
TORRENT_DIRECT_CLIENTS=$(shell_quote "$TORRENT_DIRECT_CLIENTS")
TORRENT_DIRECT_PORTS=$(shell_quote "$TORRENT_DIRECT_PORTS")
BLOCK_QUIC=$(shell_quote "$BLOCK_QUIC")
XRAY_DATADIR=$(shell_quote "$XRAY_DATADIR")
INSTALL_GEOSITE=$(shell_quote "$INSTALL_GEOSITE")
UPDATE_GEOSITE=$(shell_quote "$UPDATE_GEOSITE")
GEOSITE_URL=$(shell_quote "$GEOSITE_URL")
GEOSITE_MIN_BYTES=$(shell_quote "$GEOSITE_MIN_BYTES")
EOF
  chmod 600 /etc/xray/exit-st-cf.vars
}

install_vpn_routes_helper() {
  mkdir -p /usr/libexec
  if [ -r "$0" ]; then
    cp "$0" /usr/libexec/openwrt-fin0-setup.sh
    chmod 700 /usr/libexec/openwrt-fin0-setup.sh
  else
    warn "could not copy $0 to /usr/libexec/openwrt-fin0-setup.sh; vpn-routes apply may not work"
  fi

  cat > /usr/sbin/vpn-routes <<'EOF'
#!/bin/ash
set -eu

DOMAINS="/etc/xray/direct-domains.txt"
IPS="/etc/xray/direct-ips.txt"
RENDER="/usr/libexec/openwrt-fin0-setup.sh"

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

Domain matcher examples:
  gosuslugi.ru
  regexp:^.*\\.gosuslugi\\.ru$
  geosite:alibaba

After editing, run:
  vpn-routes apply
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
  [ -f "$RENDER" ] || die "renderer is missing at $RENDER"
  sh "$RENDER" --render-xray
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
  chmod 755 /usr/sbin/vpn-routes
}

write_xray_config() {
  local vps_domain_json sni_json fp_json pbk_json sid_json spx_json uuid_json
  local extra_direct_ip_json direct_domain_json

  vps_domain_json="$(json_escape "$VPS_DOMAIN")"
  sni_json="$(json_escape "$REALITY_SNI")"
  fp_json="$(json_escape "$REALITY_FINGERPRINT")"
  pbk_json="$(json_escape "$REALITY_PUBLIC_KEY")"
  sid_json="$(json_escape "$REALITY_SHORT_ID")"
  spx_json="$(json_escape "$REALITY_SPIDERX")"
  uuid_json="$(json_escape "$VLESS_UUID")"
  extra_direct_ip_json="$(json_tail_from_file /etc/xray/direct-ips.txt)"
  ensure_domain_rule_data /etc/xray/direct-domains.txt
  direct_domain_json="$(json_list_from_file /etc/xray/direct-domains.txt)"

  mkdir -p /etc/xray
  cat > /etc/xray/exit-st-cf.json <<EOF
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

write_xray_transparent_init() {
  local extra_bypass=""
  local ip
  local quic_rule=""
  local torrent_rules=""
  local client port

  for ip in $EXTRA_DIRECT_IPS; do
    extra_bypass="$extra_bypass, $ip"
  done
  for client in $TORRENT_DIRECT_CLIENTS; do
    for port in $TORRENT_DIRECT_PORTS; do
      torrent_rules="$torrent_rules
  nft add rule inet \$TABLE tproxy_prerouting iifname \"br-lan\" ip saddr $client tcp sport $port counter return
  nft add rule inet \$TABLE tproxy_prerouting iifname \"br-lan\" ip saddr $client udp sport $port counter return"
    done
  done
  [ -n "$torrent_rules" ] &&
    torrent_rules="
  # Keep selected BitTorrent client traffic off the Xray/VLESS path.$torrent_rules
"
  [ "$BLOCK_QUIC" = "1" ] &&
    quic_rule='  nft add rule inet $TABLE tproxy_prerouting iifname { "br-lan", "tailscale0" } udp dport 443 counter reject'

  cat > /etc/init.d/xray-transparent <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=05

TABLE="xray_transparent"
XRAY_PORT="12345"
ROUTER_DNS_PORT="53"
MARK="0x1"
ROUTE_TABLE="100"

start() {
  nft delete table inet \$TABLE 2>/dev/null || true

  ip rule del fwmark \$MARK lookup \$ROUTE_TABLE 2>/dev/null || true
  ip route flush table \$ROUTE_TABLE 2>/dev/null || true
  ip route add local 0.0.0.0/0 dev lo table \$ROUTE_TABLE
  ip rule add fwmark \$MARK lookup \$ROUTE_TABLE pref 100

  nft add table inet \$TABLE
  nft 'add chain inet xray_transparent dns_prerouting { type nat hook prerouting priority dstnat; policy accept; }'
  nft 'add chain inet xray_transparent tproxy_prerouting { type filter hook prerouting priority mangle; policy accept; }'
  nft 'add set inet xray_transparent bypass4 { type ipv4_addr; flags interval; }'
  nft add element inet xray_transparent bypass4 "{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4, $VPS_IP/32$extra_bypass }"

  nft add rule inet \$TABLE dns_prerouting iifname { "br-lan", "tailscale0" } udp dport 53 counter redirect to :\$ROUTER_DNS_PORT
  nft add rule inet \$TABLE dns_prerouting iifname { "br-lan", "tailscale0" } tcp dport 53 counter redirect to :\$ROUTER_DNS_PORT

  nft add rule inet \$TABLE tproxy_prerouting iifname { "br-lan", "tailscale0" } udp dport 53 counter return
  nft add rule inet \$TABLE tproxy_prerouting iifname { "br-lan", "tailscale0" } tcp dport 53 counter return
  nft add rule inet \$TABLE tproxy_prerouting iifname "br-lan" ct status dnat counter return
$torrent_rules
$quic_rule
  nft add rule inet \$TABLE tproxy_prerouting iifname { "br-lan", "tailscale0" } ip daddr @bypass4 counter return
  nft add rule inet \$TABLE tproxy_prerouting iifname { "br-lan", "tailscale0" } ip protocol tcp counter tproxy ip to :\$XRAY_PORT meta mark set \$MARK accept
  nft add rule inet \$TABLE tproxy_prerouting iifname { "br-lan", "tailscale0" } ip protocol udp counter tproxy ip to :\$XRAY_PORT meta mark set \$MARK accept
}

stop() {
  nft delete table inet \$TABLE 2>/dev/null || true
  ip rule del fwmark \$MARK lookup \$ROUTE_TABLE 2>/dev/null || true
  ip route flush table \$ROUTE_TABLE 2>/dev/null || true
}

restart() {
  stop
  start
}
EOF
  chmod 755 /etc/init.d/xray-transparent
}

configure_xray() {
  info "Configuring Xray"
  write_xray_route_files
  write_xray_vars
  install_vpn_routes_helper
  install_geosite_data
  write_xray_config
  xray run -test -config /etc/xray/exit-st-cf.json

  uci set xray.enabled='xray'
  uci set xray.enabled.enabled='1'
  uci set xray.config='xray'
  uci set xray.config.conffiles='/etc/xray/exit-st-cf.json'
  uci set xray.config.datadir="$XRAY_DATADIR"
  uci set xray.config.format='json'
  uci -q delete xray.config.confdir
  uci commit xray

  write_xray_transparent_init
  sh -n /etc/init.d/xray-transparent

  /etc/init.d/xray enable
  /etc/init.d/xray restart
  /etc/init.d/xray-transparent enable
  /etc/init.d/xray-transparent restart
}

render_xray_from_saved_state() {
  require_openwrt_root
  [ -f /etc/xray/exit-st-cf.vars ] || die "missing /etc/xray/exit-st-cf.vars; run full setup first"
  . /etc/xray/exit-st-cf.vars
  write_xray_route_files
  install_geosite_data
  write_xray_config
  xray run -test -config /etc/xray/exit-st-cf.json
  write_xray_transparent_init
  sh -n /etc/init.d/xray-transparent
  /etc/init.d/xray restart
  /etc/init.d/xray-transparent restart
  echo "VPN route rules applied."
}

configure_tailscale() {
  local up_args

  info "Configuring Tailscale"
  uci set tailscale.settings='settings'
  uci set tailscale.settings.log_stderr='1'
  uci set tailscale.settings.log_stdout='1'
  uci set tailscale.settings.port='41641'
  uci set tailscale.settings.state_file='/etc/tailscale/tailscaled.state'
  uci set tailscale.settings.fw_mode='nftables'
  uci commit tailscale

  /etc/init.d/tailscale enable
  /etc/init.d/tailscale restart || /etc/init.d/tailscale start
  sleep 2

  if [ "$RUN_TAILSCALE_UP" != "1" ] || [ -z "$TAILSCALE_AUTHKEY" ]; then
    warn "Tailscale service configured but tailscale up was skipped."
    warn "Run tailscale up later with --advertise-exit-node --advertise-routes=$LAN_CIDR --accept-dns=false --netfilter-mode=off"
    return
  fi

  up_args="--auth-key=$TAILSCALE_AUTHKEY --hostname=$TAILSCALE_HOSTNAME --advertise-exit-node --advertise-routes=$LAN_CIDR --accept-dns=false --netfilter-mode=off"
  if [ -n "$TAILSCALE_LOGIN_SERVER" ]; then
    tailscale up --login-server="$TAILSCALE_LOGIN_SERVER" $up_args ||
      tailscale up --reset --login-server="$TAILSCALE_LOGIN_SERVER" $up_args
  else
    tailscale up $up_args ||
      tailscale up --reset $up_args
  fi
}

validate_setup() {
  info "Validation"
  echo "OpenWrt:"
  cat /etc/openwrt_release
  echo

  echo "WAN status:"
  ifstatus wan 2>/dev/null | sed -n '1,80p' || true
  echo

  echo "Listeners:"
  netstat -lntp 2>/dev/null | grep -E ':(22|3000|5353|11808|11809|12345)[[:space:]]' || true
  echo

  echo "AdGuard DNS via dnsmasq:"
  nslookup openwrt.org 127.0.0.1 2>/dev/null || true
  echo

  echo "Router direct IPv4:"
  curl -4 -sS --connect-timeout 8 --max-time 20 http://api.ipify.org || true
  echo

  echo "Router through Xray SOCKS:"
  curl -4 -sS --connect-timeout 8 --max-time 40 \
    -x "socks5h://$LAN_IP:11808" http://api.ipify.org || true
  echo

  echo "Services:"
  /etc/init.d/dropbear enabled && echo "dropbear enabled" || true
  /etc/init.d/adguardhome enabled && echo "adguardhome enabled" || true
  /etc/init.d/xray enabled && echo "xray enabled" || true
  /etc/init.d/xray-transparent enabled && echo "xray-transparent enabled" || true
  /etc/init.d/tailscale enabled && echo "tailscale enabled" || true
  echo

  echo "Tailscale:"
  tailscale ip -4 2>/dev/null || true
  tailscale status 2>/dev/null | sed -n '1,8p' || true
  echo

  echo "nft transparent table:"
  nft list table inet xray_transparent 2>/dev/null | sed -n '1,120p' || true
}

final_notes() {
  cat <<EOF

Done.

Manual checks from a LAN client:
  curl -4 http://api.ipify.org
  curl -4 -x socks5h://$LAN_IP:11808 http://api.ipify.org

VPN direct-route editing on the router:
  vpn-routes list
  vpn-routes add-domain example.ru 'regexp:^.*\.example\.ru$'
  vpn-routes del-domain example.ru
  vpn-routes edit domains
  vpn-routes add-ip 203.0.113.10/32
  vpn-routes apply

Editable route files:
  /etc/xray/direct-domains.txt
  /etc/xray/direct-ips.txt

Tailscale/Headscale:
  Approve advertised routes for $TAILSCALE_HOSTNAME:
    0.0.0.0/0
    $LAN_CIDR

Do not add tailscale -> wan forwarding if the goal is for exit-node web traffic
to leave through Xray/VPS rather than directly through the home ISP.
Backup path:
  $(cat /root/LAST_OPENWRT_X86_FIN0_PRE_SETUP_BACKUP 2>/dev/null || true)
EOF
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    --render-xray)
      render_xray_from_saved_state
      exit 0
      ;;
  esac

  require_openwrt_root
  backup_configs
  configure_ssh_first
  check_package_space
  prompt_remaining_config
  validate_inputs
  confirm_summary
  configure_network_dhcp_firewall
  install_packages
  configure_adguard
  configure_xray
  configure_tailscale
  validate_setup
  final_notes
}

main "$@"
