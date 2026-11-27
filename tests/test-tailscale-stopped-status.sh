#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-tailscale-stopped.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$FAKE_ROOT/etc/init.d" "$FAKE_ROOT/proc/4242" "$FAKE_ROOT/tmp" \
  "$FAKE_ROOT/var/lib/tailscale"
printf 'tailscale\000status\000--json\000' > "$FAKE_ROOT/proc/4242/cmdline"
mkdir -p "$FAKE_ROOT/proc/4243"
printf '/usr/sbin/tailscaled\000--state=/var/lib/tailscale/tailscaled.state\000' > \
  "$FAKE_ROOT/proc/4243/cmdline"

cat > "$FAKE_ROOT/etc/init.d/tailscale" <<'EOF'
#!/bin/sh
case "${1:-}" in enabled) exit 1 ;; *) exit 0 ;; esac
EOF
chmod 755 "$FAKE_ROOT/etc/init.d/tailscale"

PREMIER_ROUTER_HOST_TEST=1
VPN_UI_ROOT_PREFIX="$FAKE_ROOT"
VPN_UI_PROC_ROOT="$FAKE_ROOT/proc"
VPN_UI_SOURCE_ONLY=1
UCI_BIN=true
export PREMIER_ROUTER_HOST_TEST VPN_UI_ROOT_PREFIX VPN_UI_PROC_ROOT VPN_UI_SOURCE_ONLY UCI_BIN
. "$HELPER"

PIDOF_OUTPUT=4242
pidof() { printf '%s\n' "$PIDOF_OUTPUT"; }
tailscale() {
  case "${1:-}" in
    version) printf '%s\n' '1.80.3-test' ;;
    *) printf '%s\n' "$*" >> "$TMP_ROOT/unexpected-runtime-calls"; return 1 ;;
  esac
}

tailscale_invariant_snapshot "$TMP_ROOT/stopped.txt"
[ -z "$(tailscale_snapshot_value "$TMP_ROOT/stopped.txt" pid)" ]
[ -z "$(tailscale_snapshot_value "$TMP_ROOT/stopped.txt" backend)" ]

tailscale_status_json > "$TMP_ROOT/status.json"
jq -e '.ok and (.tailscale.running | not) and (.tailscale.boot_enabled | not) and
  .tailscale.pid == "" and .tailscale.backend_state == "" and
  .tailscale.ip == "" and .tailscale.peers == []' "$TMP_ROOT/status.json" >/dev/null

[ ! -e "$TMP_ROOT/unexpected-runtime-calls" ]
PIDOF_OUTPUT='4242 4243'
[ "$(tailscale_daemon_pids)" = 4243 ]
printf '%s\n' 'Tailscale stopped-state status is nonblocking and ignores client lookalike processes'
