#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/updater-service-convergence.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

FAKE_ROOT="$TMP_ROOT/root"
TXN_ID=20260816T120000Z-0123456789abcdef
mkdir -p "$FAKE_ROOT/etc/init.d" "$FAKE_ROOT/tmp" \
  "$FAKE_ROOT/root/premier-router-updates/$TXN_ID/rollback"
: > "$TMP_ROOT/update-lib.sh"
printf '%s\n' 'uhttpd true true' > \
  "$FAKE_ROOT/root/premier-router-updates/$TXN_ID/rollback/services"

cat > "$FAKE_ROOT/etc/init.d/uhttpd" <<'EOF'
#!/bin/sh
state="${VPN_UI_TEST_SERVICE_STATE_DIR:?}/uhttpd.delay"
log="${VPN_UI_TEST_SERVICE_STATE_DIR:?}/uhttpd.observations"
case "${1:-}" in
  enabled|enable) exit 0 ;;
  disable|stop) exit 0 ;;
  restart)
    printf '%s\n' 2 > "$state"
    exit 0
    ;;
  running)
    count="$(sed -n '1p' "$state" 2>/dev/null || printf 0)"
    printf '%s\n' "$count" >> "$log"
    if [ "$count" -gt 0 ]; then
      printf '%s\n' "$((count - 1))" > "$state"
      exit 1
    fi
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$FAKE_ROOT/etc/init.d/uhttpd"

VPN_UI_TEST_SERVICE_STATE_DIR="$FAKE_ROOT/tmp"
export VPN_UI_TEST_SERVICE_STATE_DIR
VPN_UI_UPDATE_SOURCE_ONLY=1 \
VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
VPN_UI_UPDATE_PERSIST_ROOT="$FAKE_ROOT/root/premier-router-updates" \
VPN_UI_UPDATE_LIB="$TMP_ROOT/update-lib.sh" \
  . "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
TXN_DIR="$PERSIST_ROOT/$TXN_ID"

services_match
restore_services
! services_match
VPN_UI_SERVICE_MATCH_ATTEMPTS=5 services_match_wait
[ "$(sed -n '1p' "$FAKE_ROOT/tmp/uhttpd.delay")" = 0 ]
[ "$(wc -l < "$FAKE_ROOT/tmp/uhttpd.observations" | tr -d ' ')" -ge 4 ]

cat > "$FAKE_ROOT/etc/init.d/uhttpd" <<'EOF'
#!/bin/sh
case "${1:-}" in enabled|enable|restart) exit 0 ;; running) exit 1 ;; *) exit 0 ;; esac
EOF
chmod 755 "$FAKE_ROOT/etc/init.d/uhttpd"
! VPN_UI_SERVICE_MATCH_ATTEMPTS=2 services_match_wait

printf '%s\n' 'Updater rollback service convergence and bounded-timeout checks passed'
