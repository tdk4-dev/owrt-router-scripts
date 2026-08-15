#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-native-apply.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

mkdir -p "$TMP_ROOT/etc/xray/vless-profiles.d" "$TMP_ROOT/etc/init.d" "$TMP_ROOT/state"
printf '%s\n' old-config > "$TMP_ROOT/etc/xray/exit-st-cf.json"
printf '%s\n' old.example.invalid > "$TMP_ROOT/etc/xray/direct-domains.txt"
printf '%s\n' 198.51.100.0/25 > "$TMP_ROOT/etc/xray/direct-ips.txt"
printf '%s\n' current > "$TMP_ROOT/etc/xray/vless-selected"

cat > "$TMP_ROOT/etc/init.d/xray" <<'EOF'
#!/bin/sh
running="$VPN_UI_ROOT_PREFIX/state/xray-running"
case "${1:-}" in
  running) [ -f "$running" ] ;;
  restart)
    if [ "${VPN_UI_TEST_XRAY_RESTART_NO_DAEMON_ONCE:-0}" = 1 ] &&
      [ ! -f "$VPN_UI_ROOT_PREFIX/state/xray-failed-once" ]; then
      : > "$VPN_UI_ROOT_PREFIX/state/xray-failed-once"
      rm -f "$running"
      exit 0
    fi
    : > "$running"
    ;;
  start) : > "$running" ;;
  stop) rm -f "$running" ;;
  *) exit 1 ;;
esac
EOF

cat > "$TMP_ROOT/etc/init.d/xray-transparent" <<'EOF'
#!/bin/sh
FIN0_IP="198.51.100.10"
running="$VPN_UI_ROOT_PREFIX/state/transparent-running"
case "${1:-}" in
  running) [ -f "$running" ] ;;
  restart)
    if [ "${VPN_UI_TEST_TRANSPARENT_RESTART_FAIL_ONCE:-0}" = 1 ] &&
      [ ! -f "$VPN_UI_ROOT_PREFIX/state/transparent-failed-once" ]; then
      : > "$VPN_UI_ROOT_PREFIX/state/transparent-failed-once"
      rm -f "$running"
      exit 61
    fi
    : > "$running"
    ;;
  start) : > "$running" ;;
  stop) rm -f "$running" ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$TMP_ROOT/etc/init.d/xray" "$TMP_ROOT/etc/init.d/xray-transparent"

VPN_UI_SOURCE_ONLY=1 VPN_UI_ROOT_PREFIX="$TMP_ROOT" . "$HELPER"
export VPN_UI_ROOT_PREFIX
init_state() { XRAY_SERVICE=xray; }
load_profile_id() {
  P_VPS_IP=198.51.100.20
  [ "$1" = current ] && P_VPS_IP=198.51.100.10
  return 0
}
ensure_domain_rule_data() { :; }
render_xray_config() { printf 'config-for-%s\n' "$P_VPS_IP" > "$1"; }
xray_test() { [ -s "$1" ]; }

state_hash() {
  (
    for file in \
      "$TMP_ROOT/etc/xray/exit-st-cf.json" \
      "$TMP_ROOT/etc/xray/direct-domains.txt" \
      "$TMP_ROOT/etc/xray/direct-ips.txt" \
      "$TMP_ROOT/etc/xray/vless-selected" \
      "$TMP_ROOT/etc/init.d/xray-transparent"; do
      sha256sum "$file"
    done
    for marker in xray-running transparent-running; do
      [ -f "$TMP_ROOT/state/$marker" ] && printf '%s=present\n' "$marker" || printf '%s=absent\n' "$marker"
    done
  ) | sha256sum | awk '{print $1}'
}

# Profile selection while globally disabled must not activate either runtime.
render_and_apply alternate "$TMP_ROOT/etc/xray/direct-domains.txt" \
  "$TMP_ROOT/etc/xray/direct-ips.txt" 0
[ "$(cat "$TMP_ROOT/etc/xray/vless-selected")" = alternate ]
grep -Fqx 'config-for-198.51.100.20' "$TMP_ROOT/etc/xray/exit-st-cf.json"
grep -Fq 'FIN0_IP="198.51.100.20"' "$TMP_ROOT/etc/init.d/xray-transparent"
[ ! -e "$TMP_ROOT/state/xray-running" ]
[ ! -e "$TMP_ROOT/state/transparent-running" ]

# With VPN active, profile selection and direct-rule Apply preserve both live
# runtimes and commit only after their postconditions hold.
: > "$TMP_ROOT/state/xray-running"
: > "$TMP_ROOT/state/transparent-running"
render_and_apply current "$TMP_ROOT/etc/xray/direct-domains.txt" \
  "$TMP_ROOT/etc/xray/direct-ips.txt" 0
[ -f "$TMP_ROOT/state/xray-running" ]
[ -f "$TMP_ROOT/state/transparent-running" ]
printf '%s\n' new.example.invalid > "$TMP_ROOT/new-domains"
printf '%s\n' 203.0.113.0/25 > "$TMP_ROOT/new-ips"
render_and_apply alternate "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" 1
cmp -s "$TMP_ROOT/new-domains" "$TMP_ROOT/etc/xray/direct-domains.txt"
cmp -s "$TMP_ROOT/new-ips" "$TMP_ROOT/etc/xray/direct-ips.txt"

# A restart command that returns zero while the daemon is absent must fail and
# restore files plus both runtime states exactly.
before="$(state_hash)"
(
  VPN_UI_TEST_XRAY_RESTART_NO_DAEMON_ONCE=1
  export VPN_UI_TEST_XRAY_RESTART_NO_DAEMON_ONCE
  render_and_apply current "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" 0
) > "$TMP_ROOT/xray-zero-absent.json"
grep -Fq '"ok":false' "$TMP_ROOT/xray-zero-absent.json"
grep -Fq 'exact Xray configuration, route, selection, daemon, and transparent-proxy pre-state restored' \
  "$TMP_ROOT/xray-zero-absent.json"
rm -f "$TMP_ROOT/state/xray-failed-once"
[ "$(state_hash)" = "$before" ]

# Transparent restart failure has the same exact rollback guarantee.
before="$(state_hash)"
(
  VPN_UI_TEST_TRANSPARENT_RESTART_FAIL_ONCE=1
  export VPN_UI_TEST_TRANSPARENT_RESTART_FAIL_ONCE
  render_and_apply current "$TMP_ROOT/new-domains" "$TMP_ROOT/new-ips" 0
) > "$TMP_ROOT/transparent-failure.json"
grep -Fq '"ok":false' "$TMP_ROOT/transparent-failure.json"
grep -Fq 'exact Xray configuration, route, selection, daemon, and transparent-proxy pre-state restored' \
  "$TMP_ROOT/transparent-failure.json"
rm -f "$TMP_ROOT/state/transparent-failed-once"
[ "$(state_hash)" = "$before" ]

printf 'Native profile and direct-rule runtime preservation and exact rollback tests passed\n'
