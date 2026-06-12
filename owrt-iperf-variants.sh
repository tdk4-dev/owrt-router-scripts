#!/bin/bash

# Non-mutating OpenWrt -> remote iperf3 variant tests.
# Goal: distinguish ISP/CPE path limits from local TCP congestion-control artifacts.

set -u

OWRT_HOST="${OWRT_HOST:-owrt}"
REMOTE_SSH="${REMOTE_SSH:-relay-ru1}"
IPERF_SERVER="${IPERF_SERVER:-}"
IPERF_PORT="${IPERF_PORT:-5201}"
OUTPUT_BASE="${OUTPUT_BASE:-${HOME}/Downloads}"
TCP_DURATION="${TCP_DURATION:-20}"
TCP_OMIT="${TCP_OMIT:-3}"
UDP_DURATION="${UDP_DURATION:-12}"
UDP_OMIT="${UDP_OMIT:-2}"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_NAME="owrt-iperf-variants-${STAMP}"
OUT_DIR="${OUTPUT_BASE}/${RUN_NAME}"
ARCHIVE="${OUT_DIR}.tar.gz"
LOG_FILE="${OUT_DIR}/run.log"

mkdir -p "${OUT_DIR}/owrt" "${OUT_DIR}/remote"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOG_FILE}"
}

ssh_cmd() {
  local host="$1"
  shift
  ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"
}

capture_ssh() {
  local host="$1"
  local file="$2"
  shift 2
  {
    printf '# captured_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# ssh_target: %s\n' "${host}"
    printf '# remote_command: %s\n\n' "$*"
    ssh_cmd "${host}" "$*"
  } >"${OUT_DIR}/${file}" 2>&1
}

remote_public_ip() {
  ssh_cmd "${REMOTE_SSH}" '
    if command -v curl >/dev/null 2>&1; then
      curl -4fsS --max-time 10 https://api.ipify.org && exit 0
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -4 -qO- -T 10 https://api.ipify.org && exit 0
    fi
    ip -4 route get 1.1.1.1 2>/dev/null | awk '"'"'{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'"'"'
  ' 2>/dev/null | tail -n 1
}

start_server() {
  local label="$1"
  local remote_log="/tmp/${RUN_NAME}-${label}.log"
  log "Starting server for ${label}"
  ssh_cmd "${REMOTE_SSH}" "
    command -v iperf3 >/dev/null 2>&1 || { echo 'ERROR: iperf3 missing'; exit 127; }
    rm -f '${remote_log}'
    nohup iperf3 -s -p '${IPERF_PORT}' -1 > '${remote_log}' 2>&1 < /dev/null &
    srv_pid=\$!
    sleep 1
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -Eq '[:.]${IPERF_PORT}[[:space:]]' || { echo 'ERROR: iperf3 not listening'; cat '${remote_log}' 2>/dev/null || true; exit 1; }
    fi
    echo \"started pid=\${srv_pid} log=${remote_log}\"
  " >"${OUT_DIR}/remote/start-${label}.txt" 2>&1
}

run_variant() {
  local label="$1"
  local args="$2"
  start_server "${label}" || return 1
  capture_ssh "${OWRT_HOST}" "owrt/${label}.json.txt" "
    echo '==== route ===='
    ip route get '${IPERF_SERVER}' 2>/dev/null || true
    echo '==== before netdev ===='
    cat /proc/net/dev
    echo '==== iperf ===='
    iperf3 -c '${IPERF_SERVER}' -p '${IPERF_PORT}' ${args} --json
    rc=\$?
    echo '==== after netdev ===='
    cat /proc/net/dev
    exit \$rc
  "
  capture_ssh "${REMOTE_SSH}" "remote/${label}-server-log.txt" "
    cat '/tmp/${RUN_NAME}-${label}.log' 2>/dev/null || true
  "
}

if [ -z "${IPERF_SERVER}" ]; then
  log "Resolving public IPv4 for ${REMOTE_SSH}"
  IPERF_SERVER="$(remote_public_ip)"
fi

if [ -z "${IPERF_SERVER}" ]; then
  echo "ERROR: could not determine IPERF_SERVER" >&2
  exit 2
fi

log "Output: ${OUT_DIR}"
log "OpenWrt: ${OWRT_HOST}"
log "Remote: ${REMOTE_SSH}"
log "iperf endpoint: ${IPERF_SERVER}:${IPERF_PORT}"

capture_ssh "${OWRT_HOST}" "owrt/preflight.txt" "
date
uname -a
iperf3 --version 2>/dev/null | head -n 3 || true
ip route get '${IPERF_SERVER}' 2>/dev/null || true
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
cat /proc/net/dev
"

capture_ssh "${REMOTE_SSH}" "remote/preflight.txt" "
date
uname -a
iperf3 --version 2>/dev/null | head -n 3 || true
ip -4 addr show scope global 2>/dev/null || true
"

run_variant "tcp-default-p1" "-t '${TCP_DURATION}' -O '${TCP_OMIT}' -P 1"
run_variant "tcp-default-p4" "-t '${TCP_DURATION}' -O '${TCP_OMIT}' -P 4"
run_variant "tcp-default-p8" "-t '${TCP_DURATION}' -O '${TCP_OMIT}' -P 8"
run_variant "tcp-cubic-p4" "-t '${TCP_DURATION}' -O '${TCP_OMIT}' -P 4 -C cubic"
run_variant "tcp-cubic-p8" "-t '${TCP_DURATION}' -O '${TCP_OMIT}' -P 8 -C cubic"
run_variant "udp-500m-p1" "-u -b 500M -t '${UDP_DURATION}' -O '${UDP_OMIT}' -P 1"
run_variant "udp-700m-p1" "-u -b 700M -t '${UDP_DURATION}' -O '${UDP_OMIT}' -P 1"
run_variant "udp-900m-p1" "-u -b 900M -t '${UDP_DURATION}' -O '${UDP_OMIT}' -P 1"

log "Creating archive ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${OUTPUT_BASE}" "${RUN_NAME}"
log "Done"
printf '\nArchive created:\n%s\n' "${ARCHIVE}"
