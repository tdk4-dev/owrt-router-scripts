#!/bin/bash
set -euo pipefail
umask 077

VBOXMANAGE=/usr/local/bin/VBoxManage
MODE=focused
REPEAT=1
REMOTE_ROOT=
VM_NAME=
SNAPSHOT_NAME=
CANDIDATE_DIR=
EXPECTED_SOURCE_SHA=
SSH_PORT=23071
HTTPS_PORT=18443
LOCK_GRACE_SECONDS=15
STOCK_WRITABLE_BACKING_KIB=54436
STOCK_EXPECTED_DF_KIB=51352
SERVER_PID=
VM_STARTED=false
CURRENT_PHASE=initializing
CURRENT_COMMAND=none
RUN_DIR=
EVIDENCE_DIR=
SERIAL_LOG=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --root) REMOTE_ROOT="$2"; shift 2 ;;
    --vm) VM_NAME="$2"; shift 2 ;;
    --snapshot) SNAPSHOT_NAME="$2"; shift 2 ;;
    --candidate) CANDIDATE_DIR="$2"; shift 2 ;;
    --source-sha) EXPECTED_SOURCE_SHA="$2"; shift 2 ;;
    *) printf 'Unknown controller argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$MODE" = focused || "$MODE" = bridge ]]
[[ "$REPEAT" =~ ^[1-9][0-9]*$ ]] && (( REPEAT <= 50 ))
[[ "$REMOTE_ROOT" = /Users/mac-pro-host/Documents/RouterUI-local-repro ]]
[[ "$CANDIDATE_DIR" = "$REMOTE_ROOT"/assets/* ]]
[[ "$VM_NAME" =~ ^RouterUI-[A-Za-z0-9._-]+$ ]]
[[ "$SNAPSHOT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ -x "$VBOXMANAGE" ]]
[[ -d "$CANDIDATE_DIR" && -s "$CANDIDATE_DIR/SHA256SUMS" ]]

guest_ssh() {
  ssh -o BatchMode=yes -o PreferredAuthentications=none \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/tmp/router-ui-070-known-hosts \
    -o ConnectTimeout=3 -p "$SSH_PORT" root@127.0.0.1 "$@"
}

vm_state() {
  "$VBOXMANAGE" showvminfo "$VM_NAME" --machinereadable |
    sed -n 's/^VMState="\([^"]*\)"/\1/p'
}

wait_vm_poweroff() {
  local deadline=$(( $(date +%s) + 60 ))
  while [[ "$(vm_state)" != poweroff ]]; do
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}

wait_guest_ssh() {
  local deadline=$(( $(date +%s) + 150 ))
  while ! guest_ssh true >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}

wait_guest_reboot() {
  local previous_boot_id="$1" deadline=$(( $(date +%s) + 150 )) boot_id
  while :; do
    boot_id="$(guest_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    if [[ -n "$boot_id" && "$boot_id" != "$previous_boot_id" ]]; then
      sleep 2
      if guest_ssh true >/dev/null 2>&1; then
        printf '%s\n' "$boot_id"
        return 0
      fi
    fi
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}

stop_server() {
  [[ -n "$SERVER_PID" ]] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

stop_vm() {
  [[ "$VM_STARTED" = true ]] || return 0
  if [[ "$(vm_state)" = running ]]; then
    guest_ssh 'sync; poweroff' >/dev/null 2>&1 || true
    if ! wait_vm_poweroff; then
      "$VBOXMANAGE" controlvm "$VM_NAME" poweroff >/dev/null
      wait_vm_poweroff || true
    fi
  fi
  VM_STARTED=false
}

collect_guest_diagnostics() {
  [[ -n "$EVIDENCE_DIR" ]] || return 0
  [[ "$(vm_state 2>/dev/null || true)" = running ]] || return 0
  guest_ssh '
    echo "== timestamp =="; date -u +%Y-%m-%dT%H:%M:%SZ
    echo "== boot id =="; cat /proc/sys/kernel/random/boot_id
    echo "== active transaction =="; cat /root/premier-router-updates/active-transaction 2>/dev/null || true
    txn="$(sed -n "1p" /root/premier-router-updates/active-transaction 2>/dev/null)"
    echo "== journal =="; [ -n "$txn" ] && cat "/root/premier-router-updates/$txn/state.json" 2>/dev/null || true
    echo "== lock owner =="; cat /root/premier-router-updates/update.lock/owner 2>/dev/null || true
    owner="$(sed -n "s/^pid=//p" /root/premier-router-updates/update.lock/owner 2>/dev/null | sed -n "1p")"
    echo "== process list =="; ps w
    if [ -n "$owner" ] && [ -d "/proc/$owner" ]; then
      echo "== lock owner status =="; cat "/proc/$owner/status" 2>/dev/null || true
      echo "== lock owner cmdline =="; tr "\000" " " < "/proc/$owner/cmdline" 2>/dev/null || true; echo
      echo "== lock owner file descriptors =="
      for fd in "/proc/$owner/fd"/*; do [ -e "$fd" ] || continue; printf "%s -> " "$fd"; readlink "$fd" || true; done
    fi
    echo "== recovery service =="; /etc/init.d/premier-router-update-recovery enabled; echo "enabled_rc=$?" || true
    echo "== updater log =="; cat /tmp/premier-router-update.log 2>/dev/null || true
    echo "== logread recovery =="; logread 2>/dev/null | grep -E "premier-router|vpn-ui|recovery" || true
    echo "== memory and filesystems =="; grep MemTotal /proc/meminfo; df -Pk / /overlay /tmp
  ' > "$EVIDENCE_DIR/guest-diagnostics.txt" 2>&1 || true
  cp "$SERIAL_LOG" "$EVIDENCE_DIR/serial.log" 2>/dev/null || true
}

on_exit() {
  local rc=$?
  set +e
  if (( rc != 0 )); then
    collect_guest_diagnostics
    if [[ -n "$EVIDENCE_DIR" ]]; then
      {
        printf 'phase=%s\n' "$CURRENT_PHASE"
        printf 'command=%s\n' "$CURRENT_COMMAND"
        printf 'exit_code=%s\n' "$rc"
        printf 'candidate_source_sha=%s\n' "$EXPECTED_SOURCE_SHA"
        printf 'vm=%s\n' "$VM_NAME"
        printf 'snapshot=%s\n' "$SNAPSHOT_NAME"
      } > "$EVIDENCE_DIR/failure.txt"
    fi
  fi
  stop_server
  stop_vm
  exit "$rc"
}
trap on_exit EXIT INT TERM

fail() {
  printf 'LOCAL-REPRO-ERROR: %s\n' "$*" >&2
  return 1
}

validate_candidate() {
  CURRENT_PHASE=verify-immutable-candidate
  CURRENT_COMMAND='shasum -a 256 -c SHA256SUMS'
  (cd "$CANDIDATE_DIR" && shasum -a 256 -c SHA256SUMS) > "$RUN_DIR/candidate-sha256.log"
  grep -Fq "\"source_commit\": \"$EXPECTED_SOURCE_SHA\"" \
    "$CANDIDATE_DIR/router-release-manifest.json" || fail 'candidate source SHA mismatch'
  grep -Fq '"signing_key_id": "router-ui-prod-5b001ed1f9e63c96"' \
    "$CANDIDATE_DIR/router-release-manifest.json" || fail 'candidate production key ID mismatch'
}

prepare_https_server() {
  local tls="$RUN_DIR/tls" server_root="$RUN_DIR/server"
  CURRENT_PHASE=prepare-local-https
  CURRENT_COMMAND='generate ephemeral CA and start isolated HTTPS server'
  mkdir -p "$tls" "$server_root/releases/download" "$server_root/releases/latest"
  ln -s "$CANDIDATE_DIR" "$server_root/releases/download/vpn-panel-v0.7.11"
  ln -s "$CANDIDATE_DIR" "$server_root/releases/latest/download"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=Router UI local diagnostic CA' \
    -keyout "$tls/ca.key" -out "$tls/ca.crt" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -sha256 -subj '/CN=10.0.2.2' \
    -keyout "$tls/server.key" -out "$tls/server.csr" >/dev/null 2>&1
  {
    printf 'subjectAltName=IP:10.0.2.2,IP:127.0.0.1\n'
    printf 'extendedKeyUsage=serverAuth\n'
  } > "$tls/server.ext"
  openssl x509 -req -sha256 -days 1 -in "$tls/server.csr" \
    -CA "$tls/ca.crt" -CAkey "$tls/ca.key" -CAcreateserial \
    -extfile "$tls/server.ext" -out "$tls/server.crt" >/dev/null 2>&1
  ruby "$REMOTE_ROOT/runtime/https-artifact-server.rb" \
    --root "$server_root" --cert "$tls/server.crt" --key "$tls/server.key" \
    --port "$HTTPS_PORT" > "$RUN_DIR/https-server.log" 2>&1 &
  SERVER_PID=$!
  sleep 1
  kill -0 "$SERVER_PID" 2>/dev/null || fail 'isolated HTTPS server failed to start'
  curl --cacert "$tls/ca.crt" -fsS \
    "https://127.0.0.1:$HTTPS_PORT/releases/download/vpn-panel-v0.7.11/router-release-manifest.json" \
    >/dev/null
}

restore_and_start_vm() {
  local info memory
  CURRENT_PHASE=restore-clean-snapshot
  CURRENT_COMMAND="VBoxManage snapshot $VM_NAME restore $SNAPSHOT_NAME"
  [[ "$(vm_state)" = poweroff ]] || fail 'disposable VM is not powered off'
  "$VBOXMANAGE" snapshot "$VM_NAME" restore "$SNAPSHOT_NAME" >/dev/null
  info="$($VBOXMANAGE showvminfo "$VM_NAME" --machinereadable)"
  memory="$(printf '%s\n' "$info" | sed -n 's/^memory=//p')"
  [[ "$memory" = 256 ]] || fail "guest RAM is $memory MiB, expected exactly 256 MiB"
  (( memory <= 300 )) || fail 'guest exceeds the 300 MiB local ceiling'
  printf '%s\n' "$info" | grep -Fq 'nic1="nat"' || fail 'guest NIC is not isolated NAT'
  printf '%s\n' "$info" | grep -Fq "127.0.0.1,$SSH_PORT,,22" || fail 'deterministic SSH forward is missing'
  SERIAL_LOG="$(printf '%s\n' "$info" | sed -n 's/^uartmode1="file,\(.*\)"/\1/p')"
  [[ -n "$SERIAL_LOG" ]] || fail 'serial evidence file is not configured'
  : > "$SERIAL_LOG"
  CURRENT_COMMAND="VBoxManage startvm $VM_NAME --type headless"
  "$VBOXMANAGE" startvm "$VM_NAME" --type headless >/dev/null
  VM_STARTED=true
  wait_guest_ssh || fail 'guest SSH did not become ready'
}

stage_guest_runtime() {
  guest_ssh 'umask 077; cat > /tmp/router-ui-vm-guest.sh; chmod 700 /tmp/router-ui-vm-guest.sh' \
    < "$REMOTE_ROOT/runtime/router-ui-vm-guest.sh"
}

lock_observation() {
  guest_ssh "txn='$1';" '
    state="$(jsonfilter -i "/root/premier-router-updates/$txn/state.json" -e "@.state" 2>/dev/null || true)"
    lock=false; live=false; pid=; token=; owner_boot=; owner_start=
    if [ -d /root/premier-router-updates/update.lock ]; then
      lock=true
      owner=/root/premier-router-updates/update.lock/owner
      pid="$(sed -n "s/^pid=//p" "$owner" 2>/dev/null | sed -n "1p")"
      token="$(sed -n "s/^token=//p" "$owner" 2>/dev/null | sed -n "1p")"
      owner_boot="$(sed -n "s/^boot_id=//p" "$owner" 2>/dev/null | sed -n "1p")"
      owner_start="$(sed -n "s/^start_id=//p" "$owner" 2>/dev/null | sed -n "1p")"
      current_boot="$(cat /proc/sys/kernel/random/boot_id)"
      current_start="$(awk "{print \$22}" "/proc/$pid/stat" 2>/dev/null || true)"
      [ -n "$pid" ] && [ "$owner_boot" = "$current_boot" ] && [ "$owner_start" = "$current_start" ] && live=true
    fi
    printf "%s\t%s\t%s\t%s\t%s\n" "${state:-missing}" "$lock" "$live" "${pid:-none}" "${token:-none}"
  '
}

wait_for_terminal_and_unlock() {
  local transaction="$1" started now elapsed observation state lock live pid token terminal_at=-1
  CURRENT_PHASE=post-reboot-recovery
  CURRENT_COMMAND='wait for committed and owned update lock release'
  started="$(date +%s)"
  : > "$EVIDENCE_DIR/recovery-observations.tsv"
  while :; do
    now="$(date +%s)"
    elapsed=$((now - started))
    observation="$(lock_observation "$transaction")"
    IFS=$'\t' read -r state lock live pid token <<< "$observation"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" "$state" "$lock" "$live" "$pid" \
      >> "$EVIDENCE_DIR/recovery-observations.tsv"
    case "$state" in
      rollback_failed|recovery_required) fail "unsafe recovery state: $state" ;;
      committed)
        (( terminal_at < 0 )) && terminal_at=$elapsed
        [[ "$live" = false ]] || fail "terminal state coexists with owned live lock (pid=$pid token=$token)"
        [[ "$lock" = false ]] && break
        (( elapsed - terminal_at < LOCK_GRACE_SECONDS )) || \
          fail "terminal state retained a stale lock for $LOCK_GRACE_SECONDS seconds"
        ;;
    esac
    (( elapsed < 120 )) || fail 'transaction did not reach committed within 120 seconds'
    sleep 1
  done
}

assert_no_recovery_process_or_lock() {
  CURRENT_PHASE=assert-final-lifecycle
  CURRENT_COMMAND='assert recovery process exited and update lock is absent'
  guest_ssh '[ ! -d /root/premier-router-updates/update.lock ]'
  guest_ssh '! ps w | grep -E "[v]pn-ui-update recover|[p]remier-router-update-recovery"'
}

verify_candidate_state() {
  local transaction="$1" before_protected="$2" after_protected
  CURRENT_PHASE=verify-committed-candidate
  CURRENT_COMMAND='verify packages, manifest, protected hashes, storage, and service state'
  stage_guest_runtime
  guest_ssh "/tmp/router-ui-vm-guest.sh verify-target 0.7.11 0.7.0 post-reboot"
  after_protected="$(guest_ssh /tmp/router-ui-vm-guest.sh protected-hash)"
  [[ "$after_protected" = "$before_protected" ]] || fail 'protected configuration hashes changed'
  guest_ssh 'usign -q -V -p /usr/share/premier-router/keys/release.pub -m /etc/premier-router/installed-manifest.json -x /etc/premier-router/installed-manifest.json.sig'
  guest_ssh "transaction='$transaction';" '
    for package in premier-router-core luci-app-premier-router premier-router-setup; do
      [ "$(opkg status "$package" | sed -n "s/^Version: //p" | sed -n "1p")" = 0.7.11-1 ] || exit 1
    done
    [ "$(jsonfilter -i "/root/premier-router-updates/$transaction/state.json" -e "@.state")" = committed ]
  '
  guest_ssh "/tmp/router-ui-vm-guest.sh measure rd23-stock $STOCK_WRITABLE_BACKING_KIB $STOCK_EXPECTED_DF_KIB" \
    > "$EVIDENCE_DIR/final-measurement.json"
  guest_ssh '/etc/init.d/premier-router-update-recovery enabled'
  assert_no_recovery_process_or_lock
}

run_exact_rollback() {
  local transaction="$1" before_protected="$2" after_protected boot_before boot_after
  CURRENT_PHASE=exact-rollback
  CURRENT_COMMAND="sh /root/premier-router-updates/$transaction/rollback.sh"
  stage_guest_runtime
  guest_ssh "/tmp/router-ui-vm-guest.sh rollback $transaction 0.7.0"
  assert_no_recovery_process_or_lock
  after_protected="$(guest_ssh /tmp/router-ui-vm-guest.sh protected-hash)"
  [[ "$after_protected" = "$before_protected" ]] || fail 'rollback changed protected configuration hashes'
  guest_ssh '! opkg status premier-router-core luci-app-premier-router premier-router-setup 2>/dev/null | grep -q "Status:.* installed"'
  boot_before="$(guest_ssh cat /proc/sys/kernel/random/boot_id)"
  guest_ssh 'sync; reboot' >/dev/null 2>&1 || true
  boot_after="$(wait_guest_reboot "$boot_before")" || \
    fail 'restored 0.7.0 guest did not return after rollback reboot'
  stage_guest_runtime
  guest_ssh '[ "$(sed -n "1p" /usr/share/vpn-ui/version)" = 0.7.0 ]'
  guest_ssh '/usr/sbin/vpn-ui check' > "$EVIDENCE_DIR/rollback-source-validation.log"
  guest_ssh '[ ! -d /root/premier-router-updates/update.lock ]'
  after_protected="$(guest_ssh /tmp/router-ui-vm-guest.sh protected-hash)"
  [[ "$after_protected" = "$before_protected" ]] || fail 'protected hashes changed after rollback reboot'
}

run_iteration() {
  local iteration="$1" transaction before_boot after_boot before_protected rescue_rc
  RUN_DIR="$REMOTE_ROOT/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$-$iteration"
  EVIDENCE_DIR="$RUN_DIR/evidence"
  mkdir -p "$EVIDENCE_DIR"
  validate_candidate
  prepare_https_server
  restore_and_start_vm
  CURRENT_PHASE=verify-clean-baseline
  CURRENT_COMMAND='validate exact 0.7.0 baseline and RD23 stock geometry'
  stage_guest_runtime
  guest_ssh '[ "$(sed -n "1p" /usr/share/vpn-ui/version)" = 0.7.0 ]'
  guest_ssh '/usr/sbin/vpn-ui check' > "$EVIDENCE_DIR/source-validation.log"
  guest_ssh "/tmp/router-ui-vm-guest.sh measure rd23-stock $STOCK_WRITABLE_BACKING_KIB $STOCK_EXPECTED_DF_KIB" \
    > "$EVIDENCE_DIR/source-measurement.json"
  before_protected="$(guest_ssh /tmp/router-ui-vm-guest.sh protected-hash)"
  before_boot="$(guest_ssh cat /proc/sys/kernel/random/boot_id)"
  guest_ssh 'umask 077; cat > /tmp/router-ui-local-ca.pem' < "$RUN_DIR/tls/ca.crt"

  CURRENT_PHASE=install-candidate
  CURRENT_COMMAND='production-signed rescue-router-ui.sh from immutable local HTTPS bytes'
  set +e
  guest_ssh "
    export SSL_CERT_FILE=/tmp/router-ui-local-ca.pem
    curl -fsSL --proto '=https' 'https://10.0.2.2:$HTTPS_PORT/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh' -o /tmp/rescue-router-ui.sh
    chmod 700 /tmp/rescue-router-ui.sh
    ROUTER_UI_RELEASE_BASE='https://10.0.2.2:$HTTPS_PORT/releases/download/vpn-panel-v0.7.11' sh /tmp/rescue-router-ui.sh
  " > "$EVIDENCE_DIR/rescue.log" 2>&1
  rescue_rc=$?
  set -e
  [[ "$rescue_rc" = 0 ]] || fail "rescue installer failed with exit $rescue_rc"
  transaction="$(guest_ssh sed -n '1p' /root/premier-router-updates/active-transaction)"
  [[ "$transaction" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || fail "malformed transaction ID: $transaction"
  guest_ssh "cat '/root/premier-router-updates/$transaction/state.json'" > "$EVIDENCE_DIR/pending-state.json"
  guest_ssh 'cat /root/premier-router-updates/update.lock/owner 2>/dev/null || true' > "$EVIDENCE_DIR/pending-lock-owner.txt"

  CURRENT_PHASE=reboot-candidate
  CURRENT_COMMAND='reboot into synchronous recovery service'
  guest_ssh 'sync; reboot' >/dev/null 2>&1 || true
  after_boot="$(wait_guest_reboot "$before_boot")" || \
    fail 'candidate guest did not return after reboot'
  printf 'before_boot_id=%s\nafter_boot_id=%s\ntransaction_id=%s\n' \
    "$before_boot" "$after_boot" "$transaction" > "$EVIDENCE_DIR/reboot-identity.txt"
  wait_for_terminal_and_unlock "$transaction"
  verify_candidate_state "$transaction" "$before_protected"
  if [[ "$MODE" = bridge ]]; then
    run_exact_rollback "$transaction" "$before_protected"
  fi

  CURRENT_PHASE=clean-shutdown
  CURRENT_COMMAND='power off disposable guest and restore clean snapshot'
  stop_vm
  stop_server
  "$VBOXMANAGE" snapshot "$VM_NAME" restore "$SNAPSHOT_NAME" >/dev/null
  printf '%s\tPASS\t%s\t%s\t%s\n' "$iteration" "$MODE" "$transaction" "$RUN_DIR" \
    >> "$REMOTE_ROOT/evidence/recovery-lock-summary.tsv"
  printf 'Iteration %s/%s PASS (%s): %s\n' "$iteration" "$REPEAT" "$MODE" "$RUN_DIR"
}

mkdir -p "$REMOTE_ROOT/evidence" "$REMOTE_ROOT/runs"
for (( iteration=1; iteration<=REPEAT; iteration++ )); do
  run_iteration "$iteration"
done
trap - EXIT INT TERM
printf 'Mac Pro VirtualBox recovery-lock result: %s/%s PASS (%s)\n' "$REPEAT" "$REPEAT" "$MODE"
