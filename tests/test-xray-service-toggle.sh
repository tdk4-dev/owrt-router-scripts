#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-xray-toggle.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/etc/init.d" "$TMP_ROOT/usr/bin" "$TMP_ROOT/state"

cat > "$TMP_ROOT/usr/bin/uci" <<'EOF'
#!/bin/sh
state="$VPN_UI_ROOT_PREFIX/state/xray-gate"
case "${1:-}" in
  -q)
    case "${2:-}" in
      get)
        [ "${3:-}" = xray.enabled.enabled ] && [ -f "$state" ]
        cat "$state"
        ;;
      delete)
        [ "${3:-}" = xray.enabled.enabled ]
        rm -f "$state"
        ;;
      *) exit 1 ;;
    esac
    ;;
  set)
    case "${2:-}" in
      xray.enabled.enabled=0) printf '%s\n' 0 > "$state" ;;
      xray.enabled.enabled=1) printf '%s\n' 1 > "$state" ;;
      *) exit 1 ;;
    esac
    ;;
  commit)
    [ "${2:-}" = xray ]
    [ "${VPN_UI_TEST_UCI_COMMIT_FAIL:-0}" != 1 ]
    ;;
  *) exit 1 ;;
esac
EOF

cat > "$TMP_ROOT/etc/init.d/xray" <<'EOF'
#!/bin/sh
running="$VPN_UI_ROOT_PREFIX/state/xray-running"
enabled="$VPN_UI_ROOT_PREFIX/state/xray-boot-enabled"
case "${1:-}" in
  start|restart)
    [ "${VPN_UI_TEST_XRAY_START_FAIL:-0}" != 1 ] || exit 41
    [ "$(cat "$VPN_UI_ROOT_PREFIX/state/xray-gate" 2>/dev/null)" = 1 ] || exit 42
    [ "${VPN_UI_TEST_XRAY_START_NO_DAEMON:-0}" = 1 ] || : > "$running"
    ;;
  stop)
    [ "${VPN_UI_TEST_XRAY_STOP_FAIL:-0}" != 1 ] || exit 43
    [ "${VPN_UI_TEST_XRAY_STOP_STILL_RUNNING:-0}" = 1 ] || rm -f "$running"
    ;;
  running) [ -f "$running" ] ;;
  enable) : > "$enabled" ;;
  disable) rm -f "$enabled" ;;
  enabled) [ -f "$enabled" ] ;;
  *) exit 1 ;;
esac
EOF

cat > "$TMP_ROOT/etc/init.d/xray-transparent" <<'EOF'
#!/bin/sh
running="$VPN_UI_ROOT_PREFIX/state/transparent-running"
enabled="$VPN_UI_ROOT_PREFIX/state/transparent-boot-enabled"
case "${1:-}" in
  start|restart)
    [ "${VPN_UI_TEST_TRANSPARENT_START_FAIL:-0}" != 1 ] || exit 51
    [ "${VPN_UI_TEST_TRANSPARENT_START_NO_STATE:-0}" = 1 ] || : > "$running"
    ;;
  stop)
    [ "${VPN_UI_TEST_TRANSPARENT_STOP_FAIL:-0}" != 1 ] || exit 52
    [ "${VPN_UI_TEST_TRANSPARENT_STOP_STILL_RUNNING:-0}" = 1 ] || rm -f "$running"
    ;;
  running) [ -f "$running" ] ;;
  enable) : > "$enabled" ;;
  disable) rm -f "$enabled" ;;
  enabled) [ -f "$enabled" ] ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$TMP_ROOT/usr/bin/uci" "$TMP_ROOT/etc/init.d/xray" \
  "$TMP_ROOT/etc/init.d/xray-transparent"

run_function() {
  action="$1"
  shift
  env VPN_UI_SOURCE_ONLY=1 VPN_UI_ROOT_PREFIX="$TMP_ROOT" \
    VPN_UI_UCI_BIN="$TMP_ROOT/usr/bin/uci" "$@" \
    sh -c '. "$1"; init_state() { XRAY_SERVICE=xray; }; ensure_device_bypass_nft() { [ "${VPN_UI_TEST_BYPASS_FAIL:-0}" != 1 ]; }; "$2"' \
    sh "$HELPER" "$action"
}

reset_disabled() {
  rm -f "$TMP_ROOT/state/"*
  printf '%s\n' 0 > "$TMP_ROOT/state/xray-gate"
}

reset_enabled() {
  reset_disabled
  printf '%s\n' 1 > "$TMP_ROOT/state/xray-gate"
  : > "$TMP_ROOT/state/xray-running"
  : > "$TMP_ROOT/state/xray-boot-enabled"
  : > "$TMP_ROOT/state/transparent-running"
  : > "$TMP_ROOT/state/transparent-boot-enabled"
}

state_digest() {
  (
    cd "$TMP_ROOT/state"
    for file in xray-gate xray-running xray-boot-enabled \
      transparent-running transparent-boot-enabled; do
      if [ -f "$file" ]; then printf '%s=' "$file"; sha256sum "$file" | awk '{print $1}'
      else printf '%s=absent\n' "$file"; fi
    done
  ) | sha256sum | awk '{print $1}'
}

assert_disabled() {
  [ "$(cat "$TMP_ROOT/state/xray-gate")" = 0 ]
  [ ! -e "$TMP_ROOT/state/xray-running" ]
  [ ! -e "$TMP_ROOT/state/xray-boot-enabled" ]
  [ ! -e "$TMP_ROOT/state/transparent-running" ]
  [ ! -e "$TMP_ROOT/state/transparent-boot-enabled" ]
}

assert_enabled() {
  [ "$(cat "$TMP_ROOT/state/xray-gate")" = 1 ]
  [ -f "$TMP_ROOT/state/xray-running" ]
  [ -f "$TMP_ROOT/state/xray-boot-enabled" ]
  [ -f "$TMP_ROOT/state/transparent-running" ]
  [ -f "$TMP_ROOT/state/transparent-boot-enabled" ]
}

assert_failure_restored() {
  expected="$1"
  shift
  output="$(run_function "$@")"
  printf '%s' "$output" | grep -Fq '"ok":false'
  printf '%s' "$output" | grep -Fq 'exact UCI, daemon, transparent-proxy, and reboot pre-state restored'
  [ "$(state_digest)" = "$expected" ]
}

# Fully disabled -> Enable, idempotent Enable, and enabled reboot persistence.
reset_disabled
run_function start_xray_services >/dev/null
assert_enabled
enabled_digest="$(state_digest)"
run_function start_xray_services >/dev/null
[ "$(state_digest)" = "$enabled_digest" ]
rm -f "$TMP_ROOT/state/xray-running" "$TMP_ROOT/state/transparent-running"
VPN_UI_ROOT_PREFIX="$TMP_ROOT" "$TMP_ROOT/etc/init.d/xray" start
VPN_UI_ROOT_PREFIX="$TMP_ROOT" "$TMP_ROOT/etc/init.d/xray-transparent" start
assert_enabled

# Fully enabled -> Disable, idempotent Disable, and disabled reboot persistence.
run_function stop_xray_services >/dev/null
assert_disabled
disabled_digest="$(state_digest)"
run_function stop_xray_services >/dev/null
[ "$(state_digest)" = "$disabled_digest" ]
assert_disabled

# Nonzero Xray start, zero-without-daemon, transparent start failure, and
# zero-without-transparent-state all restore the exact fully-disabled pre-state.
reset_disabled
before="$(state_digest)"
assert_failure_restored "$before" start_xray_services VPN_UI_TEST_XRAY_START_FAIL=1
assert_failure_restored "$before" start_xray_services VPN_UI_TEST_XRAY_START_NO_DAEMON=1
assert_failure_restored "$before" start_xray_services VPN_UI_TEST_TRANSPARENT_START_FAIL=1
assert_failure_restored "$before" start_xray_services VPN_UI_TEST_TRANSPARENT_START_NO_STATE=1

# A late Device VPN postcondition failure restores an intentionally mixed
# UCI/runtime/reboot pre-state byte-for-byte, not a normalized approximation.
reset_disabled
: > "$TMP_ROOT/state/xray-running"
: > "$TMP_ROOT/state/transparent-running"
: > "$TMP_ROOT/state/transparent-boot-enabled"
mixed_before="$(state_digest)"
assert_failure_restored "$mixed_before" start_xray_services VPN_UI_TEST_BYPASS_FAIL=1

# Disable must detect both nonzero stop failure and a zero return that leaves
# the daemon present, restoring the exact fully-enabled pre-state.
reset_enabled
before="$(state_digest)"
assert_failure_restored "$before" stop_xray_services VPN_UI_TEST_TRANSPARENT_STOP_FAIL=1
assert_failure_restored "$before" stop_xray_services VPN_UI_TEST_XRAY_STOP_STILL_RUNNING=1

printf 'Xray lifecycle postcondition, persistence, rollback, and idempotence tests passed\n'
