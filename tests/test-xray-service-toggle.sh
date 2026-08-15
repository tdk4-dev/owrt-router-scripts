#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-xray-toggle.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/etc/init.d" "$TMP_ROOT/usr/bin" "$TMP_ROOT/state"
printf '%s\n' 0 > "$TMP_ROOT/state/xray-enabled"

cat > "$TMP_ROOT/usr/bin/uci" <<'EOF'
#!/bin/sh
state="$VPN_UI_ROOT_PREFIX/state/xray-enabled"
case "${1:-}" in
  -q)
    [ "${2:-}" = get ] && [ "${3:-}" = xray.enabled.enabled ]
    cat "$state"
    ;;
  set)
    case "${2:-}" in
      xray.enabled.enabled=0) printf '%s\n' 0 > "$state" ;;
      xray.enabled.enabled=1) printf '%s\n' 1 > "$state" ;;
      *) exit 1 ;;
    esac
    ;;
  commit) [ "${2:-}" = xray ] ;;
  *) exit 1 ;;
esac
EOF

cat > "$TMP_ROOT/etc/init.d/xray" <<'EOF'
#!/bin/sh
running="$VPN_UI_ROOT_PREFIX/state/xray-running"
case "${1:-}" in
  start)
    [ "${VPN_UI_TEST_XRAY_START_FAIL:-0}" != 1 ] || exit 41
    [ "$(cat "$VPN_UI_ROOT_PREFIX/state/xray-enabled")" = 1 ] || exit 42
    : > "$running"
    ;;
  stop) rm -f "$running" ;;
  running) [ -f "$running" ] ;;
  *) exit 1 ;;
esac
EOF

cat > "$TMP_ROOT/etc/init.d/xray-transparent" <<'EOF'
#!/bin/sh
case "${1:-}" in
  restart) [ "${VPN_UI_TEST_TRANSPARENT_START_FAIL:-0}" != 1 ] ;;
  stop) : ;;
  running) exit 1 ;;
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
    sh -c '. "$1"; init_state() { XRAY_SERVICE=xray; }; ensure_device_bypass_nft() { :; }; "$2"' \
    sh "$HELPER" "$action"
}

run_function start_xray_services
[ "$(cat "$TMP_ROOT/state/xray-enabled")" = 1 ]
[ -f "$TMP_ROOT/state/xray-running" ]

run_function stop_xray_services
[ "$(cat "$TMP_ROOT/state/xray-enabled")" = 0 ]
[ ! -e "$TMP_ROOT/state/xray-running" ]

failure_output="$(run_function start_xray_services VPN_UI_TEST_XRAY_START_FAIL=1)"
printf '%s' "$failure_output" | grep -Fq '"ok":false'
printf '%s' "$failure_output" | grep -Fq 'could not start xray'
[ "$(cat "$TMP_ROOT/state/xray-enabled")" = 0 ]
[ ! -e "$TMP_ROOT/state/xray-running" ]

failure_output="$(run_function start_xray_services VPN_UI_TEST_TRANSPARENT_START_FAIL=1)"
printf '%s' "$failure_output" | grep -Fq '"ok":false'
printf '%s' "$failure_output" | grep -Fq 'could not start xray-transparent'
[ "$(cat "$TMP_ROOT/state/xray-enabled")" = 0 ]
[ ! -e "$TMP_ROOT/state/xray-running" ]

printf 'Xray service UCI toggle tests passed\n'
