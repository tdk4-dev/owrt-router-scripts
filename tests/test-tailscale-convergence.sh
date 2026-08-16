#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HELPER="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-tailscale-convergence.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

FAKE_ROOT="$TMP_ROOT/root"
STATE_DIR="$FAKE_ROOT/state"
mkdir -p "$FAKE_ROOT/etc/init.d" "$FAKE_ROOT/var/lib/tailscale" "$FAKE_ROOT/tmp" "$STATE_DIR"
export STATE_DIR

cat > "$FAKE_ROOT/etc/init.d/tailscale" <<'EOF'
#!/bin/sh
set -u
state="$STATE_DIR"
load_identity() {
  file="$VPN_UI_ROOT_PREFIX/var/lib/tailscale/tailscaled.state"
  [ -f "$file" ] || return 0
  sed -n 's/^backend=//p' "$file" | sed -n '1p' > "$state/backend"
  sed -n 's/^ip=//p' "$file" | sed -n '1p' > "$state/ip"
  sed -n 's/^control=//p' "$file" | sed -n '1p' > "$state/control"
  sed -n 's/^tailnet=//p' "$file" | sed -n '1p' > "$state/tailnet"
}
case "${1:-}" in
  running) [ -f "$state/running" ] ;;
  enabled) [ -f "$state/enabled" ] ;;
  enable)
    [ ! -f "$state/fail-enable" ] || exit 1
    : > "$state/enabled"
    ;;
  disable)
    [ ! -f "$state/fail-disable" ] || exit 1
    rm -f "$state/enabled"
    ;;
  start)
    : > "$state/running"
    printf '%s\n' "${RESTORE_PID:-900}" > "$state/pid"
    printf '%s\n' "${RESTORE_START:-9000}" > "$state/start"
    load_identity
    ;;
  stop)
    case "$(sed -n '1p' "$state/mode" 2>/dev/null || true)" in
      stop-stuck) ;;
      stop-delayed) printf '%s\n' 2 > "$state/stop-pending" ;;
      *) rm -f "$state/running" "$state/pid" "$state/start" ;;
    esac
    ;;
  restart)
    case "$(sed -n '1p' "$state/mode" 2>/dev/null || true)" in
      restart-old) ;;
      restart-delayed)
        rm -f "$state/running" "$state/pid" "$state/start"
        printf '%s\n' 2 > "$state/restart-pending"
        ;;
      restart-backend)
        : > "$state/running"
        printf '%s\n' 201 > "$state/pid"
        printf '%s\n' 2001 > "$state/start"
        printf '%s\n' Starting > "$state/backend"
        printf '%s\n' 2 > "$state/backend-pending"
        ;;
      restart-timeout)
        : > "$state/running"
        printf '%s\n' 202 > "$state/pid"
        printf '%s\n' 2002 > "$state/start"
        printf '%s\n' Starting > "$state/backend"
        ;;
      *)
        : > "$state/running"
        printf '%s\n' 200 > "$state/pid"
        printf '%s\n' 2000 > "$state/start"
        load_identity
        ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$FAKE_ROOT/etc/init.d/tailscale"

PREMIER_ROUTER_HOST_TEST=1
VPN_UI_ROOT_PREFIX="$FAKE_ROOT"
VPN_UI_SOURCE_ONLY=1
VPN_UI_TAILSCALE_ACTION_TIMEOUT=4
VPN_UI_TAILSCALE_RESTORE_TIMEOUT=4
export PREMIER_ROUTER_HOST_TEST VPN_UI_ROOT_PREFIX VPN_UI_SOURCE_ONLY
export VPN_UI_TAILSCALE_ACTION_TIMEOUT VPN_UI_TAILSCALE_RESTORE_TIMEOUT
. "$HELPER"

sleep() { :; }

advance_mock_state() {
  local n
  if [ -f "$STATE_DIR/stop-pending" ]; then
    n="$(sed -n '1p' "$STATE_DIR/stop-pending")"
    if [ "$n" -le 1 ]; then
      rm -f "$STATE_DIR/stop-pending" "$STATE_DIR/running" "$STATE_DIR/pid" "$STATE_DIR/start"
    else
      printf '%s\n' "$((n - 1))" > "$STATE_DIR/stop-pending"
    fi
  fi
  if [ -f "$STATE_DIR/restart-pending" ]; then
    n="$(sed -n '1p' "$STATE_DIR/restart-pending")"
    if [ "$n" -le 1 ]; then
      rm -f "$STATE_DIR/restart-pending"
      : > "$STATE_DIR/running"
      printf '%s\n' 203 > "$STATE_DIR/pid"
      printf '%s\n' 2003 > "$STATE_DIR/start"
      sed -n 's/^backend=//p' "$FAKE_ROOT/var/lib/tailscale/tailscaled.state" | sed -n '1p' > "$STATE_DIR/backend"
    else
      printf '%s\n' "$((n - 1))" > "$STATE_DIR/restart-pending"
    fi
  fi
  if [ -f "$STATE_DIR/backend-pending" ]; then
    n="$(sed -n '1p' "$STATE_DIR/backend-pending")"
    if [ "$n" -le 1 ]; then
      rm -f "$STATE_DIR/backend-pending"
      sed -n 's/^backend=//p' "$FAKE_ROOT/var/lib/tailscale/tailscaled.state" | sed -n '1p' > "$STATE_DIR/backend"
    else
      printf '%s\n' "$((n - 1))" > "$STATE_DIR/backend-pending"
    fi
  fi
  if [ -f "$STATE_DIR/up-pending" ]; then
    n="$(sed -n '1p' "$STATE_DIR/up-pending")"
    if [ "$n" -le 1 ]; then
      rm -f "$STATE_DIR/up-pending"
      printf '%s\n' Running > "$STATE_DIR/backend"
      printf '%s\n' 100.64.0.55 > "$STATE_DIR/ip"
    else
      printf '%s\n' "$((n - 1))" > "$STATE_DIR/up-pending"
    fi
  fi
  if [ -f "$STATE_DIR/logout-pending" ]; then
    n="$(sed -n '1p' "$STATE_DIR/logout-pending")"
    if [ "$n" -le 1 ]; then
      rm -f "$STATE_DIR/logout-pending"
      printf '%s\n' NeedsLogin > "$STATE_DIR/backend"
      : > "$STATE_DIR/ip"
      : > "$STATE_DIR/tailnet"
    else
      printf '%s\n' "$((n - 1))" > "$STATE_DIR/logout-pending"
    fi
  fi
}

tailscale_invariant_snapshot() {
  local output="$1" pid='' start='' enabled=false backend ip control tailnet state_hash
  advance_mock_state
  [ -f "$STATE_DIR/running" ] && pid="$(sed -n '1p' "$STATE_DIR/pid")"
  [ -f "$STATE_DIR/running" ] && start="$(sed -n '1p' "$STATE_DIR/start")"
  [ -f "$STATE_DIR/enabled" ] && enabled=true
  backend="$(sed -n '1p' "$STATE_DIR/backend" 2>/dev/null || true)"
  ip="$(sed -n '1p' "$STATE_DIR/ip" 2>/dev/null || true)"
  control="$(sed -n '1p' "$STATE_DIR/control" 2>/dev/null || true)"
  tailnet="$(sed -n '1p' "$STATE_DIR/tailnet" 2>/dev/null || true)"
  state_hash=absent
  [ -f "$FAKE_ROOT/var/lib/tailscale/tailscaled.state" ] &&
    state_hash="$(sha256sum "$FAKE_ROOT/var/lib/tailscale/tailscaled.state" | awk '{print $1}')"
  {
    printf 'pid=%s\nprocess_start_id=%s\nenabled=%s\nbackend=%s\nip4=%s\n' \
      "$pid" "$start" "$enabled" "$backend" "$ip"
    printf 'control_url=%s\ntailnet=%s\n' "$control" "$tailnet"
    printf 'route_hash=route\nrule_hash=rule\n'
    printf 'management_route_hash=management-route\nmanagement_rule_hash=management-rule\n'
    printf 'state_hash=%s\n' "$state_hash"
  } > "$output"
}

tailscale_json() {
  local snapshot="$FAKE_ROOT/tmp/status.$$" pid enabled backend ip control tailnet
  tailscale_invariant_snapshot "$snapshot"
  pid="$(tailscale_snapshot_value "$snapshot" pid)"
  enabled="$(tailscale_snapshot_value "$snapshot" enabled)"
  backend="$(tailscale_snapshot_value "$snapshot" backend)"
  ip="$(tailscale_snapshot_value "$snapshot" ip4)"
  control="$(tailscale_snapshot_value "$snapshot" control_url)"
  tailnet="$(tailscale_snapshot_value "$snapshot" tailnet)"
  printf '{"running":%s,"boot_enabled":%s,"connected":%s,"pid":"%s","backend_state":"%s","ip":"%s","control_url":"%s","tailnet":"%s","peers":[]}' \
    "$([ -n "$pid" ] && printf true || printf false)" "$enabled" \
    "$([ -n "$ip" ] && printf true || printf false)" "$pid" "$backend" "$ip" "$control" "$tailnet"
  rm -f "$snapshot"
}

tailscale() {
  case "${1:-}" in
    up)
      printf '%s\n' 'backend=Running' 'ip=100.64.0.55' \
        'control=https://control.example.invalid' 'tailnet=fixture' > \
        "$FAKE_ROOT/var/lib/tailscale/tailscaled.state"
      printf '%s\n' Starting > "$STATE_DIR/backend"
      : > "$STATE_DIR/ip"
      printf '%s\n' 2 > "$STATE_DIR/up-pending"
      ;;
    logout)
      printf '%s\n' 'backend=NeedsLogin' 'ip=' \
        'control=https://control.example.invalid' 'tailnet=' > \
        "$FAKE_ROOT/var/lib/tailscale/tailscaled.state"
      printf '%s\n' Starting > "$STATE_DIR/backend"
      printf '%s\n' 2 > "$STATE_DIR/logout-pending"
      ;;
    *) return 1 ;;
  esac
}

reset_registered() {
  rm -f "$STATE_DIR"/* "$FAKE_ROOT/tmp"/vpn-ui-tailscale-action.*
  : > "$STATE_DIR/running"
  : > "$STATE_DIR/enabled"
  printf '%s\n' 100 > "$STATE_DIR/pid"
  printf '%s\n' 1000 > "$STATE_DIR/start"
  printf '%s\n' Running > "$STATE_DIR/backend"
  printf '%s\n' 100.64.0.10 > "$STATE_DIR/ip"
  printf '%s\n' https://control.example.invalid > "$STATE_DIR/control"
  printf '%s\n' fixture > "$STATE_DIR/tailnet"
  printf '%s\n' 'backend=Running' 'ip=100.64.0.10' \
    'control=https://control.example.invalid' 'tailnet=fixture' > \
    "$FAKE_ROOT/var/lib/tailscale/tailscaled.state"
}

assert_restored() {
  local before="$1" after="$TMP_ROOT/restored.$$"
  tailscale_invariant_snapshot "$after"
  tailscale_snapshot_matches_restored "$before" "$after"
  rm -f "$after"
}

# Stop: delayed disappearance succeeds only after polling.
reset_registered
printf '%s\n' stop-delayed > "$STATE_DIR/mode"
( cmd_tailscale_stop ) > "$TMP_ROOT/stop-delayed.json"
jq -e '.ok and .tailscale.running == false and .tailscale.boot_enabled == false' \
  "$TMP_ROOT/stop-delayed.json" >/dev/null

# Stop: exit zero with a remaining process times out and restores exact pre-state.
reset_registered
tailscale_invariant_snapshot "$TMP_ROOT/stop-before"
printf '%s\n' stop-stuck > "$STATE_DIR/mode"
( cmd_tailscale_stop ) > "$TMP_ROOT/stop-stuck.json"
jq -e '.ok == false and (.error | contains("exact pre-action Tailscale state was restored"))' \
  "$TMP_ROOT/stop-stuck.json" >/dev/null
assert_restored "$TMP_ROOT/stop-before"

# Stop: disable failure is critical and also restores exact pre-state.
reset_registered
tailscale_invariant_snapshot "$TMP_ROOT/disable-before"
: > "$STATE_DIR/fail-disable"
( cmd_tailscale_stop ) > "$TMP_ROOT/disable-failed.json"
jq -e '.ok == false and (.error | contains("boot disable failed"))' "$TMP_ROOT/disable-failed.json" >/dev/null
assert_restored "$TMP_ROOT/disable-before"

# Restart: unchanged old PID is rejected and restored.
reset_registered
tailscale_invariant_snapshot "$TMP_ROOT/restart-old-before"
printf '%s\n' restart-old > "$STATE_DIR/mode"
( cmd_tailscale_restart ) > "$TMP_ROOT/restart-old.json"
jq -e '.ok == false and (.error | contains("exact pre-action Tailscale state was restored"))' \
  "$TMP_ROOT/restart-old.json" >/dev/null
assert_restored "$TMP_ROOT/restart-old-before"

# Restart: delayed process appearance and delayed stable BackendState both converge.
reset_registered
printf '%s\n' restart-delayed > "$STATE_DIR/mode"
( cmd_tailscale_restart ) > "$TMP_ROOT/restart-delayed.json"
jq -e '.ok and .tailscale.running and .tailscale.backend_state == "Running"' \
  "$TMP_ROOT/restart-delayed.json" >/dev/null
reset_registered
printf '%s\n' restart-backend > "$STATE_DIR/mode"
( cmd_tailscale_restart ) > "$TMP_ROOT/restart-backend.json"
jq -e '.ok and .tailscale.running and .tailscale.backend_state == "Running"' \
  "$TMP_ROOT/restart-backend.json" >/dev/null

# Restart preserves disabled boot state, identity, control, IP, and routing.
reset_registered
rm -f "$STATE_DIR/enabled"
tailscale_invariant_snapshot "$TMP_ROOT/restart-preserve-before"
( cmd_tailscale_restart ) > "$TMP_ROOT/restart-preserve.json"
jq -e '.ok and .tailscale.running and .tailscale.boot_enabled == false and
  .tailscale.ip == "100.64.0.10" and .tailscale.tailnet == "fixture"' \
  "$TMP_ROOT/restart-preserve.json" >/dev/null
tailscale_invariant_snapshot "$TMP_ROOT/restart-preserve-after"
for key in enabled backend ip4 control_url tailnet route_hash rule_hash management_route_hash management_rule_hash; do
  [ "$(tailscale_snapshot_value "$TMP_ROOT/restart-preserve-before" "$key")" = \
    "$(tailscale_snapshot_value "$TMP_ROOT/restart-preserve-after" "$key")" ]
done

# Restart timeout restores the exact semantic pre-state.
reset_registered
tailscale_invariant_snapshot "$TMP_ROOT/restart-timeout-before"
printf '%s\n' restart-timeout > "$STATE_DIR/mode"
( cmd_tailscale_restart ) > "$TMP_ROOT/restart-timeout.json"
jq -e '.ok == false and (.error | contains("exact pre-action Tailscale state was restored"))' \
  "$TMP_ROOT/restart-timeout.json" >/dev/null
assert_restored "$TMP_ROOT/restart-timeout-before"

# Up and Logout both wait for their own delayed backend transitions without persisting an auth key.
reset_registered
printf '%s\n' NeedsLogin > "$STATE_DIR/backend"
: > "$STATE_DIR/ip"
printf '%s\n' 'backend=NeedsLogin' 'ip=' \
  'control=https://control.example.invalid' 'tailnet=' > "$FAKE_ROOT/var/lib/tailscale/tailscaled.state"
( cmd_tailscale_up https://control.example.invalid fixture tskey-secret-test '' 0 ) > "$TMP_ROOT/up.json"
jq -e '.ok and .tailscale.backend_state == "Running" and .tailscale.connected' "$TMP_ROOT/up.json" >/dev/null
! grep -R -F 'tskey-secret-test' "$FAKE_ROOT" >/dev/null 2>&1

reset_registered
( cmd_tailscale_logout ) > "$TMP_ROOT/logout.json"
jq -e '.ok and .tailscale.backend_state == "NeedsLogin" and (.tailscale.connected | not)' \
  "$TMP_ROOT/logout.json" >/dev/null

grep -Fq 'tailscale_wait_state' "$HELPER"
grep -Fq 'fwmark 0x80000/0xff0000' "$HELPER"
! sed -n '/^cmd_tailscale_stop()/,/^}/p' "$HELPER" | grep -Fq '|| true'
printf '%s\n' 'Tailscale bounded convergence, delayed success, timeout, and exact restoration checks passed'
