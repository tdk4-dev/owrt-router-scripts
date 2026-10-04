#!/bin/sh
set -eu
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/transparent-migration.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
. "$ROOT_DIR/scripts/transparent-init-migration.sh"
mkdir -p "$WORK/etc/init.d" "$WORK/usr/sbin" "$WORK/usr/libexec/premier-router"
init="$WORK/etc/init.d/xray-transparent"
cat > "$init" <<'EOF'
#!/bin/sh /etc/rc.common
TABLE="xray_transparent"
ROUTE_TABLE="100"
FIN0_IP="192.0.2.10"
# Owner endpoint and custom routing body must survive migration.
start() {
  printf '%s\n' "$FIN0_IP" > "$VPN_UI_ROOT_PREFIX/started"
}
stop() {
  rm -f "$VPN_UI_ROOT_PREFIX/started"
}
restart() { stop && start; }
EOF
cp "$init" "$WORK/original"
cp "$ROOT_DIR/luci-vpn-ui/files/etc/init.d/xray-transparent" "$init-opkg"
sha="$(sha256sum "$init-opkg" | awk '{print $1}')"
transparent_init_check "$init"
cmp -s "$init" "$WORK/original"
transparent_init_migrate "$init" "$sha"
[ ! -e "$init-opkg" ]
awk '/^# premier-router lifecycle migration v1$/ {exit} {
  sub(/^vpn_ui_legacy_start\(\)/, "start()"); print
}' "$init" | sed '${/^$/d;}' > "$WORK/restored"
cmp -s "$WORK/original" "$WORK/restored"

before="$(sha256sum "$init" | awk '{print $1}')"
cp "$ROOT_DIR/luci-vpn-ui/files/etc/init.d/xray-transparent" "$init-opkg"
transparent_init_migrate "$init" "$sha"
[ "$(sha256sum "$init" | awk '{print $1}')" = "$before" ]
printf 'tampered\n' > "$init-opkg"
! transparent_init_migrate "$init" "$sha"
[ "$(sha256sum "$init" | awk '{print $1}')" = "$before" ]
rm "$init-opkg"
cp "$init" "$WORK/altered"
printf '\n: # trailing change\n' >> "$WORK/altered"
! transparent_init_check "$WORK/altered"
ln -s "$init" "$WORK/link"
! transparent_init_check "$WORK/link"
printf '#!/bin/sh\nstart() { :; }\n' > "$WORK/unsupported"
! transparent_init_check "$WORK/unsupported"

cp "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/transparent-routing.sh" \
  "$WORK/usr/libexec/premier-router/transparent-routing.sh"
cat > "$WORK/usr/sbin/vpn-ui" <<'EOF'
#!/bin/sh
[ "$1" = device-bypass-sync ] || exit 1
[ "${VPN_UI_TEST_SYNC_FAIL:-0}" != 1 ] || exit 1
: > "$VPN_UI_ROOT_PREFIX/synced"
EOF
chmod 755 "$WORK/usr/sbin/vpn-ui"
VPN_UI_ROOT_PREFIX="$WORK"
export VPN_UI_ROOT_PREFIX
. "$init"
vpn_ui_transparent_running() {
  [ -f "$WORK/started" ] && [ -f "$WORK/synced" ]
}
! running
start
running
grep -Fqx 192.0.2.10 "$WORK/started"
stop
! running
VPN_UI_TEST_SYNC_FAIL=1
export VPN_UI_TEST_SYNC_FAIL
! start
! running
printf 'Legacy conffile body, guarded lifecycle, idempotence and refusal tests passed\n'
