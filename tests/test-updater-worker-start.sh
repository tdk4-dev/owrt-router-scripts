#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-worker-start.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$FAKE_ROOT/usr/share/vpn-ui" "$FAKE_ROOT/usr/share/premier-router" \
  "$FAKE_ROOT/proc/sys/kernel/random" "$FAKE_ROOT/tmp" "$FAKE_ROOT/root"
printf '%s\n' '0.7.11-rc.14' > "$FAKE_ROOT/usr/share/vpn-ui/version"
printf '%s\n' 'UPDATER_PROTOCOL=2' 'PACKAGE_VERSION=0.7.11~rc14-1' > \
  "$FAKE_ROOT/usr/share/premier-router/build-info"
printf '%s\n' 'worker-test-boot' > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"

run_worker() {
  env \
    PREMIER_ROUTER_HOST_TEST=1 \
    VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_UPDATE_LIB="$LIB" \
    VPN_UI_UPDATE_SELF="$UPDATER" \
    VPN_UI_DISCOVERY_BASE='http://127.0.0.1:1' \
    VPN_UI_RELEASE_ORIGIN='http://127.0.0.1:1' \
    VPN_UI_TEST_PROCESS_START_ID='worker-test-start' \
    VPN_UI_WORKER_HANDSHAKE_TIMEOUT="${VPN_UI_WORKER_HANDSHAKE_TIMEOUT:-3}" \
    VPN_UI_NOHUP_BIN="${VPN_UI_NOHUP_BIN:-nohup}" \
    VPN_UI_TEST_WORKER_SPAWN_FAIL="${VPN_UI_TEST_WORKER_SPAWN_FAIL:-0}" \
    VPN_UI_TEST_WORKER_SKIP_HANDSHAKE="${VPN_UI_TEST_WORKER_SKIP_HANDSHAKE:-0}" \
    VPN_UI_TEST_WORKER_HOLD_SECONDS="${VPN_UI_TEST_WORKER_HOLD_SECONDS:-}" \
    sh "$UPDATER" "$@"
}

wait_for_unlock() {
  count=0
  while [ -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ] && [ "$count" -lt 20 ]; do
    sleep 1
    count=$((count + 1))
  done
  [ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]
}

if VPN_UI_NOHUP_BIN=router-ui-missing-nohup run_worker check-start > "$TMP_ROOT/missing.json"; then
  printf 'missing nohup unexpectedly started a worker\n' >&2
  exit 1
fi
VPN_UI_NOHUP_BIN=nohup
jq -e '.ok == false and .error_code == "missing_nohup" and (.error | contains("coreutils-nohup")) and
  .job.kind == "check" and .job.status == "failed"' \
  "$TMP_ROOT/missing.json" >/dev/null
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]

if VPN_UI_TEST_WORKER_SPAWN_FAIL=1 run_worker check-start > "$TMP_ROOT/spawn.json"; then
  printf 'injected spawn failure unexpectedly started a worker\n' >&2
  exit 1
fi
VPN_UI_TEST_WORKER_SPAWN_FAIL=0
jq -e '.ok == false and .error_code == "worker_spawn_failed" and .job.status == "failed" and
  (.job.id | test("^[0-9a-f]{64}$"))' "$TMP_ROOT/spawn.json" >/dev/null
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]

VPN_UI_WORKER_HANDSHAKE_TIMEOUT=1
if VPN_UI_TEST_WORKER_SKIP_HANDSHAKE=1 VPN_UI_TEST_WORKER_HOLD_SECONDS=5 \
  run_worker check-start > "$TMP_ROOT/timeout.json"; then
  printf 'handshake timeout unexpectedly started a worker\n' >&2
  exit 1
fi
VPN_UI_TEST_WORKER_SKIP_HANDSHAKE=0
VPN_UI_TEST_WORKER_HOLD_SECONDS=
VPN_UI_WORKER_HANDSHAKE_TIMEOUT=3
jq -e '.ok == false and .error_code == "worker_handshake_timeout" and .job.status == "failed" and
  (.job.id | test("^[0-9a-f]{64}$"))' "$TMP_ROOT/timeout.json" >/dev/null
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]

run_worker check-start > "$TMP_ROOT/check.json"
jq -e '.ok and .started and .job.kind == "check" and
  (.job.id | test("^[0-9a-f]{64}$")) and (.job.status == "running" or .job.status == "failed" or .job.status == "succeeded")' \
  "$TMP_ROOT/check.json" >/dev/null
wait_for_unlock

run_worker apply-start > "$TMP_ROOT/apply.json"
jq -e '.ok and .started and .job.kind == "apply" and
  (.job.id | test("^[0-9a-f]{64}$")) and (.job.status == "running" or .job.status == "failed")' \
  "$TMP_ROOT/apply.json" >/dev/null
wait_for_unlock

find "$FAKE_ROOT/root/premier-router-updates/worker-handshakes" -type f -print 2>/dev/null |
  grep -q . && {
    printf 'worker handshake files were not cleaned up\n' >&2
    exit 1
  }

printf 'Updater missing-nohup, spawn failure, handshake timeout, and detached check/apply worker tests passed\n'
