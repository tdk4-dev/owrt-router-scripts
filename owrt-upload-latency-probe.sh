#!/bin/bash

# OpenWrt raw upload plus concurrent latency probes.
# Non-mutating: starts a temporary iperf3 server on a remote host, runs upload
# from OpenWrt, and records pings from OpenWrt to gateway/internet/remote.

set -u

OWRT_HOST="${OWRT_HOST:-owrt}"
REMOTE_SSH="${REMOTE_SSH:-relay-ru1}"
IPERF_SERVER="${IPERF_SERVER:-}"
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-35}"
OMIT="${OMIT:-5}"
PARALLEL="${PARALLEL:-4}"
PING_COUNT="${PING_COUNT:-230}"
PING_INTERVAL="${PING_INTERVAL:-0.2}"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_NAME="owrt-upload-latency-probe-${STAMP}"
OUTPUT_BASE="${OUTPUT_BASE:-${HOME}/Downloads}"
OUT_DIR="${OUTPUT_BASE}/${RUN_NAME}"
ARCHIVE="${OUT_DIR}.tar.gz"
LOG_FILE="${OUT_DIR}/run.log"

mkdir -p "${OUT_DIR}/owrt" "${OUT_DIR}/remote"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOG_FILE}"
}

capture_ssh() {
  local host="$1"
  local file="$2"
  shift 2
  {
    printf '# captured_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# ssh_target: %s\n' "${host}"
    printf '# remote_command: %s\n\n' "$*"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"
  } >"${OUT_DIR}/${file}" 2>&1
}

remote_public_ip() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_SSH}" '
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    if command -v curl >/dev/null 2>&1; then
      curl -4fsS --max-time 10 https://api.ipify.org && exit 0
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -4 -qO- -T 10 https://api.ipify.org && exit 0
    fi
    ip -4 route get 1.1.1.1 2>/dev/null | awk '"'"'{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'"'"'
  ' 2>/dev/null | tail -n 1
}

start_remote_iperf_server() {
  local remote_log="/tmp/${RUN_NAME}-upload.log"
  log "Starting one-shot iperf3 server on ${REMOTE_SSH}:${IPERF_PORT}"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_SSH}" "
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    command -v iperf3 >/dev/null 2>&1 || { echo 'ERROR: iperf3 missing'; exit 127; }
    rm -f '${remote_log}'
    nohup iperf3 -s -p '${IPERF_PORT}' -1 > '${remote_log}' 2>&1 < /dev/null &
    srv_pid=\$!
    sleep 1
    if command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -Eq '[:.]${IPERF_PORT}[[:space:]]' || { echo 'ERROR: iperf3 not listening'; cat '${remote_log}' 2>/dev/null || true; exit 1; }
    fi
    echo \"started pid=\${srv_pid} log=${remote_log}\"
  " >"${OUT_DIR}/remote/start-upload.txt" 2>&1
}

if [ -z "${IPERF_SERVER}" ]; then
  log "Resolving public IPv4 for ${REMOTE_SSH}"
  IPERF_SERVER="$(remote_public_ip)"
fi

if [ -z "${IPERF_SERVER}" ]; then
  echo "ERROR: could not determine IPERF_SERVER; set IPERF_SERVER or REMOTE_SSH" >&2
  exit 2
fi

log "Output: ${OUT_DIR}"
log "OpenWrt: ${OWRT_HOST}"
log "Remote: ${REMOTE_SSH}"
log "iperf endpoint: ${IPERF_SERVER}:${IPERF_PORT}"
log "duration=${DURATION}s omit=${OMIT}s parallel=${PARALLEL}; ping interval=${PING_INTERVAL}s count=${PING_COUNT}"

capture_ssh "${OWRT_HOST}" "owrt/preflight.txt" "
date
uname -a
echo
ip route get '${IPERF_SERVER}' 2>/dev/null || true
ip route get 1.1.1.1 2>/dev/null || true
echo
cat /proc/net/dev
echo
top -bn1 2>/dev/null | head -n 35 || true
"

capture_ssh "${REMOTE_SSH}" "remote/preflight.txt" "
date
uname -a
command -v iperf3 || true
iperf3 --version 2>/dev/null | head -n 3 || true
ip -4 addr show scope global 2>/dev/null || true
"

start_remote_iperf_server || {
  log "Failed to start remote iperf3 server"
  tar -czf "${ARCHIVE}" -C "${OUTPUT_BASE}" "${RUN_NAME}"
  printf '\nArchive created:\n%s\n' "${ARCHIVE}"
  exit 1
}

log "Starting OpenWrt ping monitors"
ssh -o BatchMode=yes -o ConnectTimeout=8 "${OWRT_HOST}" "PATH=/usr/sbin:/usr/bin:/sbin:/bin; date; ip route get 192.168.1.1 2>/dev/null || true; ping -c '${PING_COUNT}' -i '${PING_INTERVAL}' -W 1 192.168.1.1" >"${OUT_DIR}/owrt/ping-gateway-192.168.1.1.txt" 2>&1 &
PING_GW_PID=$!
ssh -o BatchMode=yes -o ConnectTimeout=8 "${OWRT_HOST}" "PATH=/usr/sbin:/usr/bin:/sbin:/bin; date; ip route get 1.1.1.1 2>/dev/null || true; ping -c '${PING_COUNT}' -i '${PING_INTERVAL}' -W 1 1.1.1.1" >"${OUT_DIR}/owrt/ping-internet-1.1.1.1.txt" 2>&1 &
PING_NET_PID=$!
ssh -o BatchMode=yes -o ConnectTimeout=8 "${OWRT_HOST}" "PATH=/usr/sbin:/usr/bin:/sbin:/bin; date; ip route get '${IPERF_SERVER}' 2>/dev/null || true; ping -c '${PING_COUNT}' -i '${PING_INTERVAL}' -W 1 '${IPERF_SERVER}'" >"${OUT_DIR}/owrt/ping-remote-${IPERF_SERVER}.txt" 2>&1 &
PING_REMOTE_PID=$!

sleep 3

log "Running OpenWrt upload iperf3"
capture_ssh "${OWRT_HOST}" "owrt/upload-iperf.json.txt" "
command -v iperf3 >/dev/null 2>&1 || { echo 'ERROR: iperf3 missing on OpenWrt'; exit 127; }
iperf3 -c '${IPERF_SERVER}' -p '${IPERF_PORT}' -t '${DURATION}' -O '${OMIT}' -P '${PARALLEL}' --json
"

log "Waiting for ping monitors"
wait "${PING_GW_PID}" || true
wait "${PING_NET_PID}" || true
wait "${PING_REMOTE_PID}" || true

capture_ssh "${OWRT_HOST}" "owrt/postflight.txt" "
date
ip route get '${IPERF_SERVER}' 2>/dev/null || true
echo
cat /proc/net/dev
echo
top -bn1 2>/dev/null | head -n 35 || true
"

capture_ssh "${REMOTE_SSH}" "remote/server-log.txt" "
for f in /tmp/${RUN_NAME}-*.log; do
  [ -r \"\$f\" ] || continue
  echo \"==== \$f ====\"
  cat \"\$f\"
done
"

log "Creating archive ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${OUTPUT_BASE}" "${RUN_NAME}"
log "Done"
printf '\nArchive created:\n%s\n' "${ARCHIVE}"
