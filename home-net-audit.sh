#!/bin/bash

# Non-mutating home WAN/LAN audit for macOS + OpenWrt.
# Focus: prove the raw WAN upload path before optimizing VPN/Xray.

set -u

OWRT_HOST="${OWRT_HOST:-owrt}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE_DIR="${HOME}/Downloads"
RUN_NAME="home-net-audit-${STAMP}"
OUT_DIR="${BASE_DIR}/${RUN_NAME}"
ARCHIVE="${BASE_DIR}/${RUN_NAME}.tar.gz"
LOG_FILE="${OUT_DIR}/run.log"

mkdir -p "${OUT_DIR}/mac" "${OUT_DIR}/owrt" "${OUT_DIR}/tests"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOG_FILE}"
}

redact_stream() {
  /usr/bin/perl -pe '
    s/((?:option|list)\s+(?:password|passwd|secret|key|private_key|preshared_key|psk|token|username|identity|pin|ploam|loid)\s+)(["'\''][^"'\'']*["'\'']|\S+)/$1"<REDACTED>"/ig;
    s/((?:"?(?:password|passwd|secret|private[_-]?key|preshared[_-]?key|psk|token|auth[_-]?secret|ploam|loid|username|identity|pin)"?\s*[:=]\s*))(["'\''][^"'\'']*["'\'']|\S+)/$1<REDACTED>/ig;
    s/((?:PLOAM|LOID|PPPoE password|PPPoE username)\s*[:=]\s*)\S+/$1<REDACTED>/ig;
  '
}

capture_to_file() {
  local file="$1"
  shift
  local tmp="${OUT_DIR}/${file}.tmp"
  mkdir -p "$(dirname "${OUT_DIR}/${file}")"
  {
    printf '# captured_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# command: %s\n\n' "$*"
    /bin/bash -lc "$*"
  } >"${tmp}" 2>&1
  redact_stream <"${tmp}" >"${OUT_DIR}/${file}"
  rm -f "${tmp}"
}

capture_ssh() {
  local file="$1"
  shift
  local remote_cmd="$*"
  local tmp="${OUT_DIR}/${file}.tmp"
  mkdir -p "$(dirname "${OUT_DIR}/${file}")"
  {
    printf '# captured_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# ssh_target: %s\n' "${OWRT_HOST}"
    printf '# remote_command: %s\n\n' "${remote_cmd}"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "${OWRT_HOST}" "PATH=/usr/sbin:/usr/bin:/sbin:/bin; ${remote_cmd}"
  } >"${tmp}" 2>&1
  redact_stream <"${tmp}" >"${OUT_DIR}/${file}"
  rm -f "${tmp}"
}

capture_ssh_optional() {
  local file="$1"
  shift
  capture_ssh "$file" "$*" || true
}

log "Writing audit data to ${OUT_DIR}"
log "OpenWrt SSH target: ${OWRT_HOST}"
log "No configuration changes, installs, tcpdump, speedtest, VPN, or Xray tuning will be run."

cat >"${OUT_DIR}/README_NEXT_STEPS.txt" <<'EOF'
This archive is intended to prove the raw WAN upload path before tuning VPN/Xray.

Run-order after this audit:
1. Test Mac wired through OpenWrt LAN to the same speedtest server.
2. Test Mac wired directly to the ISP router/ONT LAN, bypassing OpenWrt.
3. If direct-to-ISP upload is still low, focus on ISP CPE/ONT/line/server path.
4. If direct-to-ISP upload is high but OpenWrt path is low, instrument OpenWrt CPU/softirq/interface counters during an upload test.

Do not optimize Xray/VPN first. Xray/Tailscale are collected only as state signals.
EOF

log "Collecting local macOS diagnostics"
capture_to_file "mac/system.txt" '
date
sw_vers 2>/dev/null || true
uname -a
hostname
whoami
'

capture_to_file "mac/interfaces.txt" '
ifconfig -a
echo
echo "==== default route ===="
route -n get default 2>/dev/null || true
echo
echo "==== routing table ===="
netstat -rn
echo
echo "==== network services ===="
networksetup -listallhardwareports 2>/dev/null || true
echo
networksetup -listallnetworkservices 2>/dev/null || true
'

capture_to_file "mac/default-interface-link.txt" '
DEF_IF="$(route -n get default 2>/dev/null | awk "/interface:/{print \$2; exit}")"
DEF_GW="$(route -n get default 2>/dev/null | awk "/gateway:/{print \$2; exit}")"
echo "default_interface=${DEF_IF:-unknown}"
echo "default_gateway=${DEF_GW:-unknown}"
echo
if [ -n "${DEF_IF}" ]; then
  echo "==== ifconfig ${DEF_IF} ===="
  ifconfig "${DEF_IF}" 2>/dev/null || true
  echo
  echo "==== matching networksetup hardware port ===="
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="${DEF_IF}" '"'"'BEGIN{RS=""; FS="\n"} $0 ~ "Device: " dev {print $0 "\n"}'"'"' || true
fi
echo
echo "==== system_profiler SPEthernetDataType ===="
system_profiler SPEthernetDataType 2>/dev/null || true
'

capture_to_file "mac/networksetup-info.txt" '
networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r svc; do
  [ -z "${svc}" ] && continue
  case "${svc}" in
    \** ) continue ;;
  esac
  echo "==== ${svc} ===="
  networksetup -getinfo "${svc}" 2>/dev/null || true
  echo
  echo "DNS:"
  networksetup -getdnsservers "${svc}" 2>/dev/null || true
  echo
done
'

capture_to_file "mac/netstat-protocols.txt" '
netstat -s
'

capture_to_file "tests/mac-light-ping.txt" '
GW="$(route -n get default 2>/dev/null | awk "/gateway:/{print \$2; exit}")"
if [ -n "${GW}" ]; then
  echo "==== ping default gateway ${GW} ===="
  ping -c 5 -n "${GW}" || true
else
  echo "No default gateway detected"
fi
echo
echo "==== ping 1.1.1.1 ===="
ping -c 5 -n 1.1.1.1 || true
'

log "Checking SSH access to ${OWRT_HOST}"
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "${OWRT_HOST}" 'echo ok' >/dev/null 2>&1; then
  log "WARNING: SSH to ${OWRT_HOST} failed. Packaging local diagnostics only."
else
  log "Collecting OpenWrt diagnostics"

  capture_ssh_optional "owrt/system.txt" '
    hostname
    date
    uptime
    echo
    cat /etc/openwrt_release 2>/dev/null || true
    echo
    uname -a
    echo
    ubus call system board 2>/dev/null || true
  '

  capture_ssh_optional "owrt/ip-state.txt" '
    echo "==== ip -br link ===="
    ip -br link
    echo
    echo "==== ip -br addr ===="
    ip -br addr
    echo
    echo "==== ip -s link ===="
    ip -s link
    echo
    echo "==== ip route show table all ===="
    ip route show table all
    echo
    echo "==== ip rule show ===="
    ip rule show
  '

  capture_ssh_optional "owrt/uci-network-firewall-dhcp.txt" '
    for cfg in network firewall dhcp sqm qos; do
      echo "==== uci show ${cfg} ===="
      uci show "${cfg}" 2>/dev/null || echo "uci config ${cfg}: not present or unreadable"
      echo
    done
  '

  capture_ssh_optional "owrt/nft-ruleset.txt" '
    if command -v nft >/dev/null 2>&1; then
      nft list ruleset
    else
      echo "nft not installed/found"
    fi
  '

  capture_ssh_optional "owrt/bridge-vlan-switch.txt" '
    echo "==== bridge link ===="
    bridge link 2>/dev/null || true
    echo
    echo "==== bridge vlan ===="
    bridge vlan 2>/dev/null || true
    echo
    echo "==== swconfig ===="
    if command -v swconfig >/dev/null 2>&1; then
      for dev in $(swconfig list 2>/dev/null | awk "{print \$1}"); do
        echo "---- ${dev} ----"
        swconfig dev "${dev}" show 2>/dev/null || true
      done
    else
      echo "swconfig not installed/found"
    fi
  '

  capture_ssh_optional "owrt/ethtool-physical-interfaces.txt" '
    phys_ifs="$(for d in /sys/class/net/*; do n="${d##*/}"; [ -e "${d}/device" ] && printf "%s\n" "${n}"; done)"
    echo "physical_interfaces:"
    printf "%s\n" "${phys_ifs}"
    echo
    if command -v ethtool >/dev/null 2>&1; then
      for ifc in ${phys_ifs}; do
        echo "==== ethtool ${ifc} ===="
        ethtool "${ifc}" 2>/dev/null || true
        echo
        echo "==== ethtool -i ${ifc} ===="
        ethtool -i "${ifc}" 2>/dev/null || true
        echo
        echo "==== ethtool -k ${ifc} ===="
        ethtool -k "${ifc}" 2>/dev/null || true
        echo
        echo "==== ethtool -S ${ifc} ===="
        ethtool -S "${ifc}" 2>/dev/null || true
        echo
      done
    else
      echo "ethtool not installed/found"
      for ifc in ${phys_ifs}; do
        echo "==== sysfs ${ifc} ===="
        for f in speed duplex carrier mtu address operstate; do
          p="/sys/class/net/${ifc}/${f}"
          [ -r "${p}" ] && printf "%s=%s\n" "${f}" "$(cat "${p}" 2>/dev/null)"
        done
        echo
      done
    fi
  '

  capture_ssh_optional "owrt/proc-cpu-net.txt" '
    echo "==== /proc/interrupts ===="
    cat /proc/interrupts
    echo
    echo "==== /proc/softirqs ===="
    cat /proc/softirqs
    echo
    echo "==== /proc/net/dev ===="
    cat /proc/net/dev
    echo
    echo "==== /proc/net/snmp ===="
    cat /proc/net/snmp 2>/dev/null || true
    echo
    echo "==== /proc/net/netstat ===="
    cat /proc/net/netstat 2>/dev/null || true
  '

  capture_ssh_optional "owrt/rps-xps-irq-affinity.txt" '
    echo "==== rps_sock_flow_entries ===="
    cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    echo
    echo "==== RPS/XPS queues ===="
    for f in /sys/class/net/*/queues/rx-*/rps_cpus /sys/class/net/*/queues/rx-*/rps_flow_cnt /sys/class/net/*/queues/tx-*/xps_cpus; do
      [ -r "${f}" ] && printf "%s=%s\n" "${f}" "$(cat "${f}" 2>/dev/null)"
    done
    echo
    echo "==== IRQ affinity ===="
    for f in /proc/irq/*/smp_affinity_list /proc/irq/*/smp_affinity; do
      [ -r "${f}" ] && printf "%s=%s\n" "${f}" "$(cat "${f}" 2>/dev/null)"
    done
  '

  capture_ssh_optional "owrt/resources-processes.txt" '
    echo "==== top -bn1 ===="
    top -bn1 2>/dev/null || top -n 1 2>/dev/null || true
    echo
    echo "==== free -h ===="
    free -h 2>/dev/null || free 2>/dev/null || true
    echo
    echo "==== df -h ===="
    df -h
    echo
    echo "==== filtered processes ===="
    ps w 2>/dev/null | grep -Ei "xray|sing-box|adguard|dnsmasq|tailscale|tcpdump|irqbalance|speedtest|iperf" | grep -v grep || true
    echo
    echo "==== full process list ===="
    ps w 2>/dev/null || ps 2>/dev/null || true
  '

  capture_ssh_optional "owrt/services-packages.txt" '
    echo "==== service status ===="
    for svc in firewall network dnsmasq xray sing-box AdGuardHome adguardhome tailscale sqm irqbalance; do
      if [ -x "/etc/init.d/${svc}" ]; then
        echo "---- ${svc} ----"
        /etc/init.d/"${svc}" status 2>&1 || true
      else
        echo "---- ${svc}: no init script ----"
      fi
      echo
    done
    echo "==== selected installed packages ===="
    if command -v opkg >/dev/null 2>&1; then
      opkg list-installed | grep -Ei "sqm|qos|ethtool|irqbalance|iperf3|speedtest|xray|sing-box|tailscale|adguard|tcpdump|firewall|nft|kmod-sched|offload" || true
    else
      echo "opkg not installed/found"
    fi
  '

  capture_ssh_optional "owrt/kernel-firewall-offload-hints.txt" '
    echo "==== firewall offload UCI hints ===="
    uci show firewall 2>/dev/null | grep -Ei "flow|offload|masq|mtu|mss|redirect|tproxy|mark" || true
    echo
    echo "==== loaded modules matching routing/offload/qos ===="
    lsmod 2>/dev/null | grep -Ei "nft|nf_|flow|offload|sched|ifb|cake|fq|bbr|tproxy|xt_|ppp|vlan" || true
    echo
    echo "==== sysctl net hints ===="
    sysctl -a 2>/dev/null | grep -Ei "net.ipv4.ip_forward|net.ipv4.tcp_congestion_control|net.core.rps|net.netfilter|bbr|default_qdisc" || true
  '

  capture_ssh_optional "owrt/light-router-tests.txt" '
    GW="$(ip route show default 2>/dev/null | awk "{print \$3; exit}")"
    IFACE="$(ip route show default 2>/dev/null | awk "{for (i=1;i<=NF;i++) if (\$i==\"dev\") print \$(i+1)}" | head -n 1)"
    echo "default_gateway=${GW:-unknown}"
    echo "default_interface=${IFACE:-unknown}"
    echo
    if [ -n "${GW}" ]; then
      echo "==== ping default gateway ${GW} ===="
      ping -c 5 -W 2 "${GW}" || true
    else
      echo "No default gateway detected"
    fi
    echo
    echo "==== ping 1.1.1.1 ===="
    ping -c 5 -W 2 1.1.1.1 || true
    echo
    echo "==== public IPv4 from router ===="
    if command -v curl >/dev/null 2>&1; then
      curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 10 http://api.ipify.org 2>/dev/null || true
      echo
    elif command -v wget >/dev/null 2>&1; then
      wget -T 10 -qO- https://api.ipify.org 2>/dev/null || wget -T 10 -qO- http://api.ipify.org 2>/dev/null || true
      echo
    else
      echo "curl/wget not installed/found"
    fi
  '

  capture_ssh_optional "owrt/dmesg-link-tail.txt" '
    dmesg 2>/dev/null | grep -Ei "eth|link|duplex|speed|mtu|error|reset|broadcom|tg3|e1000|igb|r8169|bnx|irq|napi" | tail -n 250 || true
  '
fi

log "Creating archive ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${BASE_DIR}" "${RUN_NAME}"

log "Done"
printf '\nArchive created:\n%s\n' "${ARCHIVE}"
