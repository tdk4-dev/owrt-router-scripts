#!/usr/bin/env bash
set -euo pipefail

# Mac-side setup for Xiaomi RD23 / AX3000T after OpenWrt SSH is available.
# Stock-firmware exploit/flashing is intentionally a guided prerequisite because
# it depends on Xiaomi UI state and a manually set admin password.

SCRIPT_NAME="$(basename "$0")"
KNOWN_HOSTS="${KNOWN_HOSTS:-/tmp/rd23-openwrt-known-hosts}"

ROUTER_HOST="${ROUTER_HOST:-192.168.1.1}"
ROUTER_USER="${ROUTER_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_selfhost}"
HOSTNAME="${HOSTNAME:-Exlet-OWRT}"

LAN_IP="${LAN_IP:-10.77.0.1}"
LAN_NETMASK="${LAN_NETMASK:-255.255.255.0}"
LAN_CIDR="${LAN_CIDR:-10.77.0.0/24}"
LAN_DHCP_START="${LAN_DHCP_START:-100}"
LAN_DHCP_LIMIT="${LAN_DHCP_LIMIT:-150}"

WIFI_COUNTRY="${WIFI_COUNTRY:-RU}"
WIFI_2G_SSID="${WIFI_2G_SSID:-Exlet-OWRT-2.4}"
WIFI_5G_SSID="${WIFI_5G_SSID:-Exlet-OWRT-5}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

VLESS_URL="${VLESS_URL:-}"
HEADSCALE_URL="${HEADSCALE_URL:-https://tdk4.duckdns.org}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-valera-owrt}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_SSH_CIDR="${TAILSCALE_SSH_CIDR:-100.64.0.0/10}"

INSTALL_PACKAGES="${INSTALL_PACKAGES:-0}"
APPLY_NETWORK="${APPLY_NETWORK:-1}"
RUN_TAILSCALE_UP="${RUN_TAILSCALE_UP:-auto}"
INITIAL_LAN_IP=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

headscale_host() {
  local host
  host="${HEADSCALE_URL#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  printf '%s' "$host"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command on Mac: $1"
}

usage() {
  cat <<USAGE
Usage:
  VLESS_URL='vless://...' WIFI_PASSWORD='...' ./$SCRIPT_NAME

Common environment variables:
  ROUTER_HOST=192.168.1.1          OpenWrt SSH host before LAN readdress
  SSH_KEY=~/.ssh/id_ed25519_selfhost
  HOSTNAME=Exlet-OWRT
  LAN_IP=10.77.0.1
  WIFI_2G_SSID=Exlet-OWRT-2.4
  WIFI_5G_SSID=Exlet-OWRT-5
  WIFI_PASSWORD='strong-password'
  HEADSCALE_URL=https://tdk4.duckdns.org
  TAILSCALE_HOSTNAME=valera-owrt
  TAILSCALE_AUTHKEY=tskey-auth-...  Optional; required only for first login
  INSTALL_PACKAGES=1               Optional opkg install of xray/tailscale/etc

Prerequisite:
  If the router is still on Xiaomi firmware, open its web UI first, finish the
  initial setup, and set the admin password. Run your known RD23 OpenWrt exploit
  manually, then run this script after root SSH to OpenWrt works.
USAGE
}

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o StrictHostKeyChecking=accept-new
)

if [[ -n "$SSH_KEY" ]]; then
  ssh_opts+=(-i "$SSH_KEY")
fi

rssh_host() {
  local host="$1"
  shift
  ssh "${ssh_opts[@]}" "${ROUTER_USER}@${host}" "$@"
}

rssh() {
  rssh_host "$ROUTER_HOST" "$@"
}

wait_for_ssh() {
  local host="$1"
  local label="$2"
  local i
  for i in $(seq 1 60); do
    if rssh_host "$host" 'cat /etc/openwrt_release >/dev/null 2>&1' >/dev/null 2>&1; then
      printf 'SSH ready at %s (%s)\n' "$host" "$label"
      return 0
    fi
    sleep 2
  done
  return 1
}

transfer() {
  local local_file="$1"
  local remote_file="$2"
  rssh "cat > '$remote_file'" < "$local_file"
}

prompt_if_missing() {
  if [[ -z "$VLESS_URL" ]]; then
    read -r -p 'Paste VLESS URL: ' VLESS_URL
  fi
  if [[ -z "$WIFI_PASSWORD" ]]; then
    read -r -s -p 'Wi-Fi password: ' WIFI_PASSWORD
    printf '\n'
  fi
}

manual_prereq() {
  cat <<'TEXT'
Manual prerequisite for stock Xiaomi firmware:
  1. Plug Mac Ethernet into a Xiaomi LAN port.
  2. Open the Xiaomi web UI.
  3. Complete initial setup and set the admin password.
  4. Run your known RD23 OpenWrt exploit/flashing flow.
  5. Continue here once OpenWrt root SSH is reachable.

This script does not implement the exploit because that step is firmware- and
UI-state-dependent. The reproducible part starts at OpenWrt SSH.
TEXT
}

preflight() {
  need_cmd ssh
  need_cmd python3
  need_cmd sed
  [[ -n "$VLESS_URL" ]] || die "VLESS_URL is required"
  [[ -n "$WIFI_PASSWORD" ]] || die "WIFI_PASSWORD is required"
  [[ ${#WIFI_PASSWORD} -ge 8 ]] || die "WIFI_PASSWORD must be at least 8 characters"
}

vless_endpoint_ip() {
  VLESS_URL="$VLESS_URL" python3 - <<'PY'
import ipaddress
import os
import urllib.parse

u = urllib.parse.urlsplit(os.environ["VLESS_URL"])
try:
    ipaddress.IPv4Address(u.hostname or "")
except Exception:
    raise SystemExit("VLESS_URL host must be an IPv4 literal for nft endpoint bypass")
print(u.hostname)
PY
}

generate_xray_config() {
  local out="$1"
  VLESS_URL="$VLESS_URL" LAN_IP="$LAN_IP" python3 - "$out" <<'PY'
import json
import ipaddress
import os
import sys
import urllib.parse

out = sys.argv[1]
url = os.environ["VLESS_URL"]
lan_ip = os.environ["LAN_IP"]

if not url.startswith("vless://"):
    raise SystemExit("VLESS_URL must start with vless://")

u = urllib.parse.urlsplit(url)
q = {k: v[-1] for k, v in urllib.parse.parse_qs(u.query).items()}

required = ["encryption", "flow", "fp", "pbk", "security", "sid", "sni", "spx", "type"]
missing = [k for k in required if not q.get(k)]
if missing:
    raise SystemExit("VLESS_URL missing keys: " + ", ".join(missing))
if q["security"] != "reality" or q["type"] != "tcp":
    raise SystemExit("Only VLESS TCP Reality URLs are supported")
if q["flow"] != "xtls-rprx-vision":
    raise SystemExit("Expected explicit flow=xtls-rprx-vision")
if not u.hostname or not u.port or not u.username:
    raise SystemExit("VLESS_URL must include uuid, host, and port")
try:
    ipaddress.IPv4Address(u.hostname)
except Exception:
    raise SystemExit("VLESS_URL host must be an IPv4 literal for transparent endpoint bypass")

direct_domains = [
    "regexp:^.*\\.ru$", "regexp:^.*\\.su$", "regexp:^.*\\.xn--p1ai$",
    "government.ru", "gov.ru", "gosuslugi.ru", "www.gosuslugi.ru",
    "lk.gosuslugi.ru", "esia.gosuslugi.ru", "id.gosuslugi.ru",
    "epgu.gosuslugi.ru", "pos.gosuslugi.ru", "gu-st.ru",
    "regexp:^.*\\.gosuslugi\\.ru$", "regexp:^.*\\.gu-st\\.ru$",
    "emias.info", "regexp:^.*\\.emias\\.info$", "emias.ru",
    "regexp:^.*\\.emias\\.ru$", "emias.mos.ru", "lk.emias.mos.ru",
    "ap.emias.mos.ru", "ap-emias.mos.ru", "regexp:^.*\\.emias\\.mos\\.ru$",
    "mos.ru", "login.mos.ru", "my.mos.ru", "lk.mos.ru",
    "regexp:^.*\\.mos\\.ru$", "mosgorzdrav.ru",
    "regexp:^.*\\.mosgorzdrav\\.ru$", "mosmedzdrav.ru",
    "regexp:^.*\\.mosmedzdrav\\.ru$", "gostelemed.ru",
    "regexp:^.*\\.gostelemed\\.ru$", "dr-telemed.ru",
    "regexp:^.*\\.dr-telemed\\.ru$", "nalog.ru", "cbr.ru", "moex.com",
    "mosreg.ru", "spb.ru", "kremlin.ru", "mil.ru", "sberbank.ru",
    "sbermarket.ru", "sbermegamarket.ru", "tbank-online.com", "tinkoff.ru",
    "cdn-tinkoff.ru", "alfa-bank.com", "alfa-bank.ru", "alfabank.com",
    "alfabank.ru", "vtb.com", "vtb.ru", "vtb24.ru", "gazprombank.ru",
    "gpb.ru", "psbank.ru", "rshb.ru", "nspk.ru", "yandex", "ya.ru",
    "yandex.ru", "yandex.com", "yandex.net", "yandex.cloud",
    "yandex-team.ru", "yastatic.net", "yastat.net", "yandexadexchange.net",
    "vk.com", "vk.ru", "vk.me", "vk.cc", "vk-cdn.net", "vk-cdn.me",
    "vkuser.net", "userapi.com", "mail.ru", "ok.ru", "okcdn.ru", "dzen.ru",
    "rutube.ru", "rutubelist.ru", "avito.ru", "www.avito.ru", "m.avito.ru",
    "tvoe.live", "regexp:^.*\\.tvoe\\.live$",
    "api.avito.ru", "pro-api.avito.ru", "static.avito.ru",
    "regexp:^.*\\.avito\\.ru$", "avito.st", "www.avito.st",
    "regexp:^.*\\.avito\\.st$", "ozon.ru", "ozone.ru",
    "ozonusercontent.com", "wildberries.ru", "wb.ru", "dns-shop.ru",
    "market.yandex.ru", "megamarket.ru", "magnit.ru", "vkusvill.ru",
    "5ka.ru", "perekrestok.ru", "dixy.ru", "2gis.ru", "2gis.com",
    "2gis.kz", "2gis.uz", "auto.ru", "hh.ru", "banki.ru", "rbc.ru",
    "kommersant.ru", "kp.ru", "gazeta.ru", "iz.ru", "mts.ru", "mymts.ru",
    "megafon.ru", "beeline.ru", "tele2.ru", "t2.ru", "yota.ru",
    "rostelecom.ru", "rt.ru", "rzd.ru", "rzd-bonus.ru", "aeroflot.ru",
    "domclick.ru", "dom.ru", "pochta.ru", "kaspersky.ru", "kaspersky.com",
    "drweb.ru", "1c.ru", "1cfresh.com", "bitrix24.ru", "timeweb.cloud",
    "timeweb.com", "fastvps.ru", "boosty.to", "donationalerts.com",
    "okko.tv", "okko.sport", "kinopoisk.ru", "clstorage.net",
    "static-storage.net",
]

def uniq(items):
    seen = set()
    out_items = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out_items.append(item)
    return out_items

private = [
    "0.0.0.0/8", "10.0.0.0/8", f"{u.hostname}",
    "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4",
    "240.0.0.0/4",
]

cfg = {
  "log": {"loglevel": "warning", "access": "/tmp/xray-access.log", "error": "/tmp/xray-error.log"},
  "inbounds": [
    {
      "tag": "socks-in", "listen": lan_ip, "port": 11808, "protocol": "socks",
      "settings": {"auth": "noauth", "udp": True},
      "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True}
    },
    {
      "tag": "transparent-in", "port": 12345, "protocol": "dokodemo-door",
      "settings": {"network": "tcp,udp", "followRedirect": True},
      "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
      "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy", "protocol": "vless",
      "settings": {"vnext": [{"address": u.hostname, "port": u.port, "users": [{
        "id": u.username, "encryption": q["encryption"], "flow": q["flow"]
      }]}]},
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "fingerprint": q["fp"], "serverName": q["sni"], "publicKey": q["pbk"],
          "shortId": q["sid"], "spiderX": q["spx"]
        }
      }
    },
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": private, "outboundTag": "direct"},
      {"type": "field", "domain": uniq(direct_domains), "outboundTag": "direct"},
      {"type": "field", "inboundTag": ["socks-in", "transparent-in"], "outboundTag": "proxy"}
    ]
  }
}

with open(out, "w") as f:
    json.dump(cfg, f, indent=2)
PY
}

generate_transparent_init() {
  local out="$1"
  local endpoint_ip
  endpoint_ip="$(vless_endpoint_ip)"
  cat > "$out" <<EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10

TABLE='xray_transparent'
LAN_IF='br-lan'
LAN_IP='$LAN_IP'
TPROXY_PORT='12345'
MARK='1'
RT_TABLE='100'

start() {
  ip route replace local default dev lo table "\$RT_TABLE"
  ip rule show | grep -q "fwmark 0x1.*lookup \$RT_TABLE" || ip rule add fwmark "\$MARK" table "\$RT_TABLE"
  nft delete table inet "\$TABLE" 2>/dev/null || true
  nft -f - <<NFT
table inet \$TABLE {
  set bypass4 {
    type ipv4_addr
    flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, $endpoint_ip, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }
  }
  chain dns_redirect {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "\$LAN_IF" udp dport 53 ip daddr != \$LAN_IP dnat ip to \$LAN_IP
    iifname "\$LAN_IF" tcp dport 53 ip daddr != \$LAN_IP dnat ip to \$LAN_IP
  }
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    iifname != "\$LAN_IF" return
    ip daddr @bypass4 return
    udp dport 53 return
    tcp dport 53 return
    meta l4proto tcp tproxy to :\$TPROXY_PORT meta mark set \$MARK accept
    meta l4proto udp tproxy to :\$TPROXY_PORT meta mark set \$MARK accept
  }
}
NFT
}

stop() {
  nft delete table inet "\$TABLE" 2>/dev/null || true
  while ip rule del fwmark "\$MARK" table "\$RT_TABLE" 2>/dev/null; do :; done
  ip route flush table "\$RT_TABLE" 2>/dev/null || true
}
EOF
}

configure_packages() {
  if [[ "$INSTALL_PACKAGES" != "1" ]]; then
    info "Checking required router binaries"
    rssh "command -v xray >/dev/null && command -v tailscale >/dev/null && command -v nft >/dev/null && command -v curl >/dev/null" ||
      die "router is missing xray/tailscale/nft/curl. Re-run with INSTALL_PACKAGES=1 if opkg internet is available."
    return
  fi

  info "Installing required packages with opkg"
  rssh 'opkg update && opkg install xray-core tailscale curl nftables'
}

configure_base_system() {
  info "Configuring hostname, LAN/WAN, DHCP, DNS, firewall, and Wi-Fi"
  local headscale_host_q
  local wifi_password_q
  headscale_host_q="$(sh_quote "$(headscale_host)")"
  wifi_password_q="$(sh_quote "$WIFI_PASSWORD")"
  rssh "sh" <<EOF
set -e
HEADSCALE_HOST=$headscale_host_q
WIFI_PASSWORD=$wifi_password_q

uci set system.@system[0].hostname='$HOSTNAME'
uci commit system
echo '$HOSTNAME' > /proc/sys/kernel/hostname

uci set network.lan=interface
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$LAN_IP'
uci set network.lan.netmask='$LAN_NETMASK'
uci set network.lan.ip6assign='0'
uci set network.wan=interface
uci set network.wan.device='wan'
uci set network.wan.proto='dhcp'
uci commit network

uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci set dhcp.@dnsmasq[0].rebind_protection='0'
uci set dhcp.lan='dhcp'
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='$LAN_DHCP_START'
uci set dhcp.lan.limit='$LAN_DHCP_LIMIT'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.dhcpv4='server'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.force='1'
uci -q delete dhcp.lan.dhcp_option
uci add_list dhcp.lan.dhcp_option='3,$LAN_IP'
uci add_list dhcp.lan.dhcp_option='6,$LAN_IP'
uci set dhcp.wan='dhcp'
uci set dhcp.wan.ignore='1'
uci commit dhcp

WAN_ZONE="\$(uci show firewall | sed -n "s/^\\(firewall\\.[^.]*\\)\\.name='wan'\$/\\1/p" | sed -n '1p')"
[ -n "\$WAN_ZONE" ] || WAN_ZONE='firewall.@zone[1]'
uci set "\$WAN_ZONE.masq=1"
uci set "\$WAN_ZONE.mtu_fix=1"
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci -q delete firewall.valera_lan_wan
uci set firewall.valera_lan_wan='forwarding'
uci set firewall.valera_lan_wan.src='lan'
uci set firewall.valera_lan_wan.dest='wan'
uci -q delete firewall.allow_tailscale_ssh
uci set firewall.allow_tailscale_ssh='rule'
uci set firewall.allow_tailscale_ssh.name='Allow-Tailscale-SSH'
uci set firewall.allow_tailscale_ssh.src='*'
uci set firewall.allow_tailscale_ssh.src_ip='$TAILSCALE_SSH_CIDR'
uci set firewall.allow_tailscale_ssh.proto='tcp'
uci set firewall.allow_tailscale_ssh.dest_port='22'
uci set firewall.allow_tailscale_ssh.target='ACCEPT'
uci commit firewall

uci set wireless.radio0.country='$WIFI_COUNTRY'
uci set wireless.radio0.disabled='0'
uci set wireless.default_radio0='wifi-iface'
uci set wireless.default_radio0.device='radio0'
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.mode='ap'
uci set wireless.default_radio0.ssid='$WIFI_2G_SSID'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key="\$WIFI_PASSWORD"
uci set wireless.default_radio0.disabled='0'
uci set wireless.radio1.country='$WIFI_COUNTRY'
uci set wireless.radio1.disabled='0'
uci set wireless.default_radio1='wifi-iface'
uci set wireless.default_radio1.device='radio1'
uci set wireless.default_radio1.network='lan'
uci set wireless.default_radio1.mode='ap'
uci set wireless.default_radio1.ssid='$WIFI_5G_SSID'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.key="\$WIFI_PASSWORD"
uci set wireless.default_radio1.disabled='0'
uci commit wireless

cp /etc/hosts /etc/hosts.bak.rd23-setup 2>/dev/null || true
grep -F -v "\$HEADSCALE_HOST" /etc/hosts.bak.rd23-setup > /tmp/hosts.production 2>/dev/null || true
if [ -s /tmp/hosts.production ]; then
  cp /tmp/hosts.production /etc/hosts
fi
EOF
}

configure_xray() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  generate_xray_config "$tmpdir/xray.json"
  generate_transparent_init "$tmpdir/xray-transparent"

  info "Installing Xray and transparent proxy config"
  transfer "$tmpdir/xray.json" /tmp/rd23-xray.json
  transfer "$tmpdir/xray-transparent" /tmp/rd23-xray-transparent
  rssh <<'EOF'
set -e
mkdir -p /etc/xray
xray run -test -config /tmp/rd23-xray.json
cp /etc/xray/config.json /etc/xray/config.json.bak.rd23-setup 2>/dev/null || true
cp /tmp/rd23-xray.json /etc/xray/config.json
cp /tmp/rd23-xray-transparent /etc/init.d/xray-transparent
chmod 755 /etc/init.d/xray-transparent
sh -n /etc/init.d/xray-transparent
/etc/init.d/xray enable
/etc/init.d/xray restart
/etc/init.d/xray-transparent enable
/etc/init.d/xray-transparent restart
EOF
  rm -rf "$tmpdir"
}

configure_tailscale() {
  info "Configuring or validating Tailscale/Headscale"
  rssh "/etc/init.d/tailscale enable"

  local has_ip=0
  if rssh "tailscale ip -4 >/dev/null 2>&1"; then
    has_ip=1
  fi

  if [[ "$RUN_TAILSCALE_UP" == "1" || ( "$RUN_TAILSCALE_UP" == "auto" && "$has_ip" == "0" ) ]]; then
    [[ -n "$TAILSCALE_AUTHKEY" ]] || die "Tailscale is not logged in. Provide TAILSCALE_AUTHKEY or log in manually."
    rssh "tailscale up --login-server $(sh_quote "$HEADSCALE_URL") --auth-key $(sh_quote "$TAILSCALE_AUTHKEY") --hostname $(sh_quote "$TAILSCALE_HOSTNAME") --accept-routes=false"
  fi
}

apply_services() {
  info "Applying services"
  rssh "/etc/init.d/firewall restart"
  rssh "/etc/init.d/dnsmasq restart"
  rssh "wifi reload || /etc/init.d/network reload || true"
}

maybe_apply_network() {
  if [[ "$APPLY_NETWORK" != "1" ]]; then
    return
  fi

  local current_lan
  current_lan="$INITIAL_LAN_IP"
  if [[ -z "$current_lan" ]]; then
    current_lan="$(rssh "uci -q get network.lan.ipaddr || true" | tr -d '\r')"
  fi
  if [[ "$current_lan" == "$LAN_IP" ]]; then
    return
  fi

  info "LAN IP changes from $current_lan to $LAN_IP"
  cat <<EOF
The script will restart networking. Your Mac may need to renew DHCP or reconnect
Ethernet. After the restart, this script will wait for SSH at $LAN_IP.
EOF
  read -r -p "Press Enter to restart router networking..."
  rssh "sh -c 'sleep 2; /etc/init.d/network restart' >/tmp/rd23-network-restart.log 2>&1 &" || true
  ROUTER_HOST="$LAN_IP"
  wait_for_ssh "$ROUTER_HOST" "new LAN IP" || die "could not reach router at $LAN_IP after network restart"
}

validate() {
  info "Validating production setup"
  local headscale_host
  headscale_host="$(headscale_host)"
  rssh <<EOF
set -e
echo hostname
cat /proc/sys/kernel/hostname
echo wan
ifstatus wan | sed -n '1,80p'
echo dns
nslookup "$headscale_host"
echo direct_ip
curl -4 -sS --connect-timeout 8 --max-time 20 http://api.ipify.org || true
echo
echo socks_ip
curl -4 -sS --connect-timeout 8 --max-time 40 -x socks5h://$LAN_IP:11808 http://api.ipify.org || true
echo
echo xray
/etc/init.d/xray status
echo transparent
/etc/init.d/xray-transparent enabled && echo enabled || echo disabled
echo tailscale
tailscale ip -4 || true
tailscale status | sed -n '1,5p' || true
echo route_checks
: > /tmp/xray-access.log
curl -4 -k -sS -o /dev/null --connect-timeout 8 --max-time 20 -x socks5h://$LAN_IP:11808 https://emias.info/ || true
curl -4 -k -sS -o /dev/null --connect-timeout 8 --max-time 20 -x socks5h://$LAN_IP:11808 https://esia.gosuslugi.ru/ || true
cat /tmp/xray-access.log
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  manual_prereq
  prompt_if_missing
  preflight

  info "Waiting for OpenWrt SSH at $ROUTER_HOST"
  wait_for_ssh "$ROUTER_HOST" "initial" || die "OpenWrt SSH is not reachable at $ROUTER_HOST"
  INITIAL_LAN_IP="$(rssh "uci -q get network.lan.ipaddr || true" | tr -d '\r')"

  configure_packages
  configure_base_system
  configure_xray
  configure_tailscale
  apply_services
  maybe_apply_network
  validate

  info "Done"
  cat <<EOF
Production notes:
  - No /etc/hosts override for tdk4.duckdns.org is kept.
  - SSH over tailnet is allowed from $TAILSCALE_SSH_CIDR to TCP/22.
  - Transparent proxy bypasses private ranges, Tailscale, and the VLESS endpoint.
  - Russian, EMIAS, and ESIA/Gosuslugi domains are routed direct by Xray.
EOF
}

main "$@"
