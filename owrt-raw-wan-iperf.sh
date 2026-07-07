#!/bin/bash

# OpenWrt-originated raw WAN iperf3 test.
# This tests: OpenWrt CPU/NIC -> ISP router/ONT -> internet -> iperf3 server.
# It does not test LAN-to-WAN forwarding and does not modify OpenWrt config.

set -u

OWRT_HOST="${OWRT_HOST:-owrt}"
REMOTE_SSH="${REMOTE_SSH:-}"
IPERF_SERVER="${IPERF_SERVER:-}"
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-25}"
OMIT="${OMIT:-3}"
PARALLEL="${PARALLEL:-4}"
RUN_DOWNLOAD="${RUN_DOWNLOAD:-1}"

STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_NAME="owrt-raw-wan-iperf-${STAMP}"
OUT_DIR="${HOME}/Downloads/${RUN_NAME}"
ARCHIVE="${OUT_DIR}.tar.gz"
LOG_FILE="${OUT_DIR}/run.log"

mkdir -p "${OUT_DIR}/owrt" "${OUT_DIR}/remote"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOG_FILE}"
}

capture_local() {
  local file="$1"
  shift
  {
    printf '# captured_at: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# command: %s\n\n' "$*"
    /bin/bash -lc "$*"
  } >"${OUT_DIR}/${file}" 2>&1
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
  local label="$1"
  local remote_log="/tmp/${RUN_NAME}-${label}.log"
  if [ -z "${REMOTE_SSH}" ]; then
    log "REMOTE_SSH not set; assuming iperf3 server is already listening on ${IPERF_SERVER}:${IPERF_PORT}"
    return 0
  fi

  log "Starting one-shot iperf3 server on ${REMOTE_SSH}:${IPERF_PORT} for ${label}"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "${REMOTE_SSH}" "
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    if ! command -v iperf3 >/dev/null 2>&1; then
      echo 'ERROR: iperf3 is not installed on remote host ${REMOTE_SSH}'
      echo 'Install it on the VPS or choose another REMOTE_SSH/IPERF_SERVER.'
      exit 127
    fi
    rm -f '${remote_log}'
    nohup iperf3 -s -p '${IPERF_PORT}' -1 > '${remote_log}' 2>&1 < /dev/null &
    srv_pid=\$!
    sleep 1
    if command -v ss >/dev/null 2>&1; then
      if ! ss -ltn 2>/dev/null | grep -Eq '[:.]${IPERF_PORT}[[:space:]]'; then
        echo 'ERROR: iperf3 server did not start listening on port ${IPERF_PORT}'
        cat '${remote_log}' 2>/dev/null || true
        exit 1
      fi
    fi
    echo \"started iperf3 server pid=\${srv_pid} port=${IPERF_PORT} log=${remote_log}\"
  " >"${OUT_DIR}/remote/start-${label}.txt" 2>&1; then
    cat "${OUT_DIR}/remote/start-${label}.txt" >&2
    return 1
  fi
  sleep 1
}

owrt_snapshot_cmd() {
  local label="$1"
  cat <<EOF
echo "label=${label}"
date
echo
echo "==== route to iperf server ===="
ip route get '${IPERF_SERVER}' 2>/dev/null || true
echo
echo "==== /proc/net/dev ===="
cat /proc/net/dev
echo
echo "==== /proc/softirqs ===="
cat /proc/softirqs
echo
echo "==== /proc/interrupts ===="
cat /proc/interrupts
echo
echo "==== top ===="
top -bn1 2>/dev/null | head -n 45 || top -n 1 2>/dev/null | head -n 45 || true
echo
echo "==== nft xray counters, if present ===="
nft list table inet xray_transparent 2>/dev/null || true
EOF
}

run_owrt_iperf() {
  local label="$1"
  local extra_args="$2"
  log "Running OpenWrt iperf3 ${label}: server=${IPERF_SERVER} port=${IPERF_PORT} duration=${DURATION}s parallel=${PARALLEL}"
  capture_ssh "${OWRT_HOST}" "owrt/${label}.txt" \
    "command -v iperf3 >/dev/null 2>&1 || { echo 'iperf3 not installed on OpenWrt'; exit 127; }; iperf3 -c '${IPERF_SERVER}' -p '${IPERF_PORT}' -t '${DURATION}' -O '${OMIT}' -P '${PARALLEL}' ${extra_args} --json"
}

log "Writing results to ${OUT_DIR}"
log "OpenWrt target: ${OWRT_HOST}"

if [ -z "${IPERF_SERVER}" ]; then
  if [ -n "${REMOTE_SSH}" ]; then
    log "Resolving public IPv4 for REMOTE_SSH=${REMOTE_SSH}"
    IPERF_SERVER="$(remote_public_ip)"
  fi
fi

if [ -z "${IPERF_SERVER}" ]; then
  cat >&2 <<EOF
ERROR: Set either:
  REMOTE_SSH=your-vps-ssh-alias
or:
  IPERF_SERVER=public.ip.or.hostname

Examples:
  REMOTE_SSH=remote-iperf-host ./owrt-raw-wan-iperf.sh
  IPERF_SERVER=203.0.113.10 ./owrt-raw-wan-iperf.sh
EOF
  exit 2
fi

log "iperf3 server endpoint: ${IPERF_SERVER}:${IPERF_PORT}"

capture_local "local-context.txt" '
date
uname -a
route -n get default 2>/dev/null || true
'

capture_ssh "${OWRT_HOST}" "owrt/preflight.txt" "
date
uname -a
echo
command -v iperf3 || true
iperf3 --version 2>/dev/null | head -n 3 || true
echo
ip route show table all
echo
ip rule show
"

if [ -n "${REMOTE_SSH}" ]; then
  capture_ssh "${REMOTE_SSH}" "remote/preflight.txt" "
date
uname -a
echo
command -v iperf3 || true
iperf3 --version 2>/dev/null | head -n 3 || true
echo
ip -4 addr show scope global 2>/dev/null || true
"
fi

capture_ssh "${OWRT_HOST}" "owrt/before-upload.txt" "$(owrt_snapshot_cmd before-upload)"
start_remote_iperf_server "upload" || {
  log "Remote iperf3 server setup failed; creating archive with diagnostics."
  tar -czf "${ARCHIVE}" -C "${HOME}/Downloads" "${RUN_NAME}"
  printf '\nArchive created:\n%s\n' "${ARCHIVE}"
  exit 1
}
run_owrt_iperf "upload-owrt-to-internet" ""
capture_ssh "${OWRT_HOST}" "owrt/after-upload.txt" "$(owrt_snapshot_cmd after-upload)"

if [ "${RUN_DOWNLOAD}" = "1" ]; then
  capture_ssh "${OWRT_HOST}" "owrt/before-download.txt" "$(owrt_snapshot_cmd before-download)"
  start_remote_iperf_server "download" || {
    log "Remote iperf3 server setup failed before download; creating archive with diagnostics."
    tar -czf "${ARCHIVE}" -C "${HOME}/Downloads" "${RUN_NAME}"
    printf '\nArchive created:\n%s\n' "${ARCHIVE}"
    exit 1
  }
  run_owrt_iperf "download-internet-to-owrt" "-R"
  capture_ssh "${OWRT_HOST}" "owrt/after-download.txt" "$(owrt_snapshot_cmd after-download)"
fi

if [ -n "${REMOTE_SSH}" ]; then
  capture_ssh "${REMOTE_SSH}" "remote/server-logs.txt" "
for f in /tmp/${RUN_NAME}-*.log; do
  [ -r \"\$f\" ] || continue
  echo \"==== \$f ====\"
  cat \"\$f\"
  echo
done
"
fi

log "Creating archive ${ARCHIVE}"
tar -czf "${ARCHIVE}" -C "${HOME}/Downloads" "${RUN_NAME}"
log "Done"

printf '\nArchive created:\n%s\n' "${ARCHIVE}"
