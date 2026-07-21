#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
USIGN_BIN="${TEST_USIGN_BIN:-$(command -v usign || true)}"
[ -x "$USIGN_BIN" ] || { printf 'usign is required for transaction tests\n' >&2; exit 1; }
export USIGN_BIN
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-transaction-test.XXXXXX")"
cleanup() {
  if [ "${KEEP_TRANSACTION_TEST_TMP:-0}" = 1 ]; then
    printf 'transaction test workspace retained at %s\n' "$TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT INT TERM
stage() { printf 'transaction-test stage: %s\n' "$1"; }

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)"
SECRET="$TMP_ROOT/test.sec"
PUBLIC="$TMP_ROOT/test.pub"
"$USIGN_BIN" -G -s "$SECRET" -p "$PUBLIC" -c 'Router UI transaction ephemeral test key'
KEY_ID="test-$($USIGN_BIN -F -p "$PUBLIC")"
TRUST_ROOT="$TMP_ROOT/trust-root"
TRUST_REGISTRY="$TRUST_ROOT/keys/release/trusted-keys.json"
mkdir -p "$TRUST_ROOT/keys/release"
cp "$PUBLIC" "$TRUST_ROOT/keys/release/test.pub"
jq -n --arg key_id "$KEY_ID" --arg fingerprint "$($USIGN_BIN -F -p "$PUBLIC")" \
  '{schema_version:1,active_key_id:$key_id,keys:[{
    key_id:$key_id,fingerprint:$fingerprint,status:"active",
    creation_date:"2026-07-21",public_key_path:"keys/release/test.pub"}]}' \
  > "$TRUST_REGISTRY"
ROUTER_UI_TRUSTED_KEYS_FILE="$TRUST_REGISTRY"
ROUTER_UI_TRUST_ROOT="$TRUST_ROOT"
ROUTER_UI_SIGNING_KEY_ID="$KEY_ID"
ROUTER_UI_SIGNING_KEY="$SECRET"
export ROUTER_UI_TRUSTED_KEYS_FILE ROUTER_UI_TRUST_ROOT
export ROUTER_UI_SIGNING_KEY_ID ROUTER_UI_SIGNING_KEY
SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  BUILD_DIR="$TMP_ROOT/build" \
  OUT_DIR="$TMP_ROOT/ipk" FEED_DIR="$TMP_ROOT/feed" \
  "$ROOT_DIR/scripts/build-openwrt-ipks.sh" >/dev/null
OUT_ROOT="$TMP_ROOT/stage-root" IPK_DIR="$TMP_ROOT/ipk" RELEASE_DIR="$TMP_ROOT/release" \
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/stage-router-release.sh" >/dev/null
printf '%s\n' "$KEY_ID" > "$TMP_ROOT/release-key-id"

FAKE_OPKG="$TMP_ROOT/opkg"
FAKE_SYSUPGRADE="$TMP_ROOT/sysupgrade"
cat > "$FAKE_OPKG" <<'EOF'
#!/bin/sh
set -eu
db="$FAKE_ROOT/var/lib/fake-opkg"
mkdir -p "$db" "$FAKE_ROOT/usr/lib/opkg/info"
write_status() {
  : > "$FAKE_ROOT/usr/lib/opkg/status"
  for record in "$db"/*; do
    [ -f "$record" ] || continue
    pkg="$(basename "$record")"
    version="$(cat "$record")"
    printf 'Package: %s\nVersion: %s\nStatus: install user installed\n\n' "$pkg" "$version" >> "$FAKE_ROOT/usr/lib/opkg/status"
  done
}
case "${1:-}" in
  status)
    [ -f "$db/$2" ] || exit 1
    printf 'Package: %s\nVersion: %s\nStatus: install user installed\n' "$2" "$(cat "$db/$2")"
    ;;
  install)
    ipk="${3:-}"
    control="$(tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./control)"
    pkg="$(printf '%s\n' "$control" | sed -n 's/^Package: //p')"
    version="$(printf '%s\n' "$control" | sed -n 's/^Version: //p')"
    [ "${FAKE_OPKG_FAIL_PACKAGE:-}" != "$pkg" ] || exit 42
    keep="$FAKE_ROOT/tmp/conffile.keep"
    [ ! -f "$FAKE_ROOT/etc/vpn-ui-update.conf" ] || cp "$FAKE_ROOT/etc/vpn-ui-update.conf" "$keep"
    tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$FAKE_ROOT"
    [ ! -f "$keep" ] || { cp "$keep" "$FAKE_ROOT/etc/vpn-ui-update.conf"; rm -f "$keep"; }
    printf '%s\n' "$version" > "$db/$pkg"
    printf '%s\n' "$control" > "$FAKE_ROOT/usr/lib/opkg/info/$pkg.control"
    tar -xzOf "$ipk" ./data.tar.gz | tar -tzf - > "$FAKE_ROOT/usr/lib/opkg/info/$pkg.list"
    write_status
    if [ "$pkg" = premier-router-core ]; then
      cat > "$FAKE_ROOT/usr/sbin/vpn-ui" <<'EOS'
#!/bin/sh
[ "${1:-}" = check ] || exit 1
printf '{"ok":true}\n'
EOS
      chmod 755 "$FAKE_ROOT/usr/sbin/vpn-ui"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$FAKE_SYSUPGRADE" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = -b ]
tar -czf "$2" -C "$FAKE_ROOT" etc/config etc/vpn-ui-update.conf
EOF
chmod 755 "$FAKE_OPKG" "$FAKE_SYSUPGRADE"

make_service() {
  service="$1"
  cat > "$FAKE_ROOT/etc/init.d/$service" <<'EOF'
#!/bin/sh
case "${1:-}" in enabled|running|enable|disable|restart|stop) exit 0 ;; *) exit 1 ;; esac
EOF
  chmod 755 "$FAKE_ROOT/etc/init.d/$service"
}
reset_source() {
  source_version="${1:-0.7.10}"
  FAKE_ROOT="$TMP_ROOT/root"
  export FAKE_ROOT
  rm -rf "$FAKE_ROOT"
  mkdir -p "$FAKE_ROOT/usr/share/vpn-ui" "$FAKE_ROOT/usr/share/luci/menu.d" \
    "$FAKE_ROOT/www/luci-static/resources/view/status/include" "$FAKE_ROOT/usr/sbin" \
    "$FAKE_ROOT/usr/lib/opkg/info" "$FAKE_ROOT/etc/config" "$FAKE_ROOT/etc/init.d" \
    "$FAKE_ROOT/etc/crontabs" "$FAKE_ROOT/etc/premier-router" "$FAKE_ROOT/tmp" \
    "$FAKE_ROOT/root" "$FAKE_ROOT/proc/sys/kernel/random"
  printf '%s\n' "$source_version" > "$FAKE_ROOT/usr/share/vpn-ui/version"
  printf '{"admin/update":{"action":{"path":"system/update"}}}\n' > "$FAKE_ROOT/usr/share/luci/menu.d/luci-app-vpn-ui.json"
  case "$source_version" in
    0.7.0|0.7.1|0.7.2|0.7.3|0.7.4|0.7.5|0.7.6|0.7.8)
      printf 'source versioned card\n' > \
        "$FAKE_ROOT/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js"
      ;;
    *)
      printf 'source canonical card\n' > \
        "$FAKE_ROOT/www/luci-static/resources/view/status/include/35_vpn.js"
      ;;
  esac
  if [ "$source_version" = 0.7.9 ]; then
    printf 'source legacy alias card\n' > "$FAKE_ROOT/www/luci-static/resources/view/status/include/_35_vpn.js"
  fi
  cat > "$FAKE_ROOT/usr/sbin/vpn-ui" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$FAKE_ROOT/usr/sbin/vpn-ui"
  printf "AUTO_UPDATE='1'\nAUTO_SCHEDULE='Sunday 04:17'\n" > "$FAKE_ROOT/etc/vpn-ui-update.conf"
  printf '17 4 * * 0 source cron\n' > "$FAKE_ROOT/etc/crontabs/root"
  printf 'config interface loopback\n' > "$FAKE_ROOT/etc/config/network"
  printf 'source opkg database\n' > "$FAKE_ROOT/usr/lib/opkg/status"
  printf 'boot-test-id\n' > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
  printf "DISTRIB_RELEASE='24.10.5'\nDISTRIB_TARGET='x86/64'\n" > "$FAKE_ROOT/etc/openwrt_release"
  : > "$FAKE_ROOT/etc/premier-router/test-mode"
  for service in cron rpcd uhttpd xray-transparent; do make_service "$service"; done
  SOURCE_FINGERPRINT="$(cd "$FAKE_ROOT" && find etc usr www -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print $1}')"
  export SOURCE_FINGERPRINT
}

run_update() {
  invocation="$1"
  shift
  env PREMIER_ROUTER_HOST_TEST=1 FAKE_ROOT="$FAKE_ROOT" \
    PR_USIGN_BIN="$USIGN_BIN" \
    PR_OPENWRT_RELEASE_FILE="$FAKE_ROOT/etc/openwrt_release" \
    VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_UPDATE_LIB="$TMP_ROOT/release/router-update-lib.sh" \
    VPN_UI_UPDATE_SELF="$TMP_ROOT/release/router-update-supervisor" \
    VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC" \
    VPN_UI_RELEASE_KEY_ID_FILE="$TMP_ROOT/release-key-id" \
    VPN_UI_OPKG_BIN="$FAKE_OPKG" VPN_UI_SYSUPGRADE_BIN="$FAKE_SYSUPGRADE" \
    VPN_UI_UPDATE_RESTART_CRON=0 "$@" \
    sh "$TMP_ROOT/release/router-update-supervisor" apply-local "$TMP_ROOT/release" \
      "$TMP_ROOT/release/router-release-manifest.json" \
      "$TMP_ROOT/release/router-release-manifest.json.sig" "$invocation" no
}

run_supervisor() {
  env PREMIER_ROUTER_HOST_TEST=1 FAKE_ROOT="$FAKE_ROOT" \
    PR_USIGN_BIN="$USIGN_BIN" \
    PR_OPENWRT_RELEASE_FILE="$FAKE_ROOT/etc/openwrt_release" \
    VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_UPDATE_LIB="$TMP_ROOT/release/router-update-lib.sh" \
    VPN_UI_UPDATE_SELF="$TMP_ROOT/release/router-update-supervisor" \
    VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC" \
    VPN_UI_RELEASE_KEY_ID_FILE="$TMP_ROOT/release-key-id" \
    VPN_UI_OPKG_BIN="$FAKE_OPKG" VPN_UI_SYSUPGRADE_BIN="$FAKE_SYSUPGRADE" \
    VPN_UI_UPDATE_RESTART_CRON=0 \
    sh "$TMP_ROOT/release/router-update-supervisor" "$@"
}

reset_source 0.7.0
legacy_status="$FAKE_ROOT/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js"
legacy_status_sha="$(sha256sum "$legacy_status" | awk '{print $1}')"
if ! run_update manual > "$TMP_ROOT/070-success.log" 2> "$TMP_ROOT/070-success.err"; then
  cat "$TMP_ROOT/070-success.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  find "$FAKE_ROOT/root/premier-router-updates" -name state.json -exec cat {} \; >&2 2>/dev/null || true
  exit 1
fi
stage 070-applied
[ ! -e "$legacy_status" ]
[ -s "$FAKE_ROOT/www/luci-static/resources/view/status/include/35_vpn.js" ]
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
printf '%s\n' "$transaction" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$'
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .worker_ownership_token "$journal" | wc -c | tr -d ' ')" -eq 65 ]
grep -qx '/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js' \
  "$FAKE_ROOT/root/premier-router-updates/$transaction/rollback/paths.list"
run_supervisor rollback "$transaction"
stage 070-rolled-back
[ ! -e "$FAKE_ROOT/www/luci-static/resources/view/status/include/35_vpn.js" ]
[ "$(sha256sum "$legacy_status" | awk '{print $1}')" = "$legacy_status_sha" ]

reset_source 0.7.9
if ! run_update manual > "$TMP_ROOT/079-success.log" 2> "$TMP_ROOT/079-success.err"; then
  cat "$TMP_ROOT/079-success.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  find "$FAKE_ROOT/root/premier-router-updates" -name state.json -exec cat {} \; >&2 2>/dev/null || true
  exit 1
fi
stage 079-applied
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.11 ]
[ -s "$FAKE_ROOT/www/luci-static/resources/view/status/include/35_vpn.js" ]
grep -q PREMIER_ROUTER_079_COMPAT_NOOP \
  "$FAKE_ROOT/www/luci-static/resources/view/status/include/_35_vpn.js"
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = committed_pending_reboot_validation ]
[ "$(run_supervisor status | jq -r '.job.status')" = pending_reboot ]
printf 'boot-after-079\n' > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
run_supervisor recover
stage 079-recovered
[ "$(jq -r .state "$journal")" = committed ]
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]
[ ! -e "$FAKE_ROOT/www/luci-static/resources/view/status/include/_35_vpn.js" ]

reset_source 0.7.10
if ! run_update manual > "$TMP_ROOT/success.log" 2> "$TMP_ROOT/success.err"; then
  cat "$TMP_ROOT/success.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  find "$FAKE_ROOT/root/premier-router-updates" -name state.json -exec cat {} \; >&2 2>/dev/null || true
  exit 1
fi
stage 0710-applied
grep -q 'Router UI 0.7.11 committed' "$TMP_ROOT/success.log"
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.11 ]
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = committed_pending_reboot_validation ]
[ "$(jq -r .needs_reboot_validation "$journal")" = true ]
[ "$(jq -r .mutation_started "$journal")" = true ]
[ "$(jq -r .rollback_status "$journal")" = not_started ]
[ -s "$FAKE_ROOT/root/premier-router-updates/$transaction/openwrt-configuration-recovery.tar.gz" ]
[ -x "$FAKE_ROOT/root/premier-router-updates/$transaction/rollback.sh" ]
if ! FAKE_ROOT="$FAKE_ROOT" PREMIER_ROUTER_HOST_TEST=1 \
  PR_USIGN_BIN="$USIGN_BIN" \
  VPN_UI_ROOT_PREFIX="$FAKE_ROOT" VPN_UI_UPDATE_LIB="$TMP_ROOT/release/router-update-lib.sh" \
  VPN_UI_UPDATE_SELF="$TMP_ROOT/release/router-update-supervisor" \
  VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC" VPN_UI_RELEASE_KEY_ID_FILE="$TMP_ROOT/release-key-id" \
  VPN_UI_OPKG_BIN="$FAKE_OPKG" VPN_UI_SYSUPGRADE_BIN="$FAKE_SYSUPGRADE" \
  sh "$TMP_ROOT/release/router-update-supervisor" rollback "$transaction"; then
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  cat "$journal" >&2
  rollback_dir="$FAKE_ROOT/root/premier-router-updates/$transaction/rollback"
  for pair in \
    'source.fingerprint restored.fingerprint' \
    'protected-source.fingerprint protected-restored.fingerprint' \
    'source.fingerprint validated-source.fingerprint' \
    'protected-source.fingerprint validated-protected.fingerprint'
  do
    set -- $pair
    if [ -f "$rollback_dir/$1" ] && [ -f "$rollback_dir/$2" ]; then
      diff -u "$rollback_dir/$1" "$rollback_dir/$2" >&2 || true
    fi
  done
  exit 1
fi
stage 0710-rolled-back
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.10 ]
[ "$(jq -r .state "$journal")" = rolled_back ]
[ "$(jq -r .rollback_status "$journal")" = succeeded ]
[ "$(stat -c '%a' "$FAKE_ROOT/usr/sbin/vpn-ui" 2>/dev/null ||
  stat -f '%Lp' "$FAKE_ROOT/usr/sbin/vpn-ui")" = 755 ]
! find "$FAKE_ROOT/root/premier-router-updates" -name '*.new.*' -print | grep -q .

# Idempotent exact-source rollback must validate without mutating into a false success.
FAKE_ROOT="$FAKE_ROOT" PREMIER_ROUTER_HOST_TEST=1 \
  PR_USIGN_BIN="$USIGN_BIN" \
  VPN_UI_ROOT_PREFIX="$FAKE_ROOT" VPN_UI_UPDATE_LIB="$TMP_ROOT/release/router-update-lib.sh" \
  VPN_UI_UPDATE_SELF="$TMP_ROOT/release/router-update-supervisor" \
  VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC" VPN_UI_RELEASE_KEY_ID_FILE="$TMP_ROOT/release-key-id" \
  VPN_UI_OPKG_BIN="$FAKE_OPKG" sh "$TMP_ROOT/release/router-update-supervisor" rollback "$transaction"
stage idempotent-rollback
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]

reset_source
if run_update auto VPN_UI_TEST_FAIL_AFTER=validating VPN_UI_TEST_FAIL_MODE=return; then
  printf 'injected validator-boundary failure returned success\n' >&2
  exit 1
fi
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = rolled_back ]
[ "$(jq -r .rollback_status "$journal")" = succeeded ]
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.10 ]
[ "$(find "$FAKE_ROOT/root/premier-router-updates/quarantine" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ]
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]
stage validator-failure-rollback

reset_source
if run_update auto FAKE_OPKG_FAIL_PACKAGE=luci-app-premier-router; then
  printf 'injected package failure returned success\n' >&2
  exit 1
fi
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = rolled_back ]
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.10 ]
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]
stage package-failure-rollback

# Lock ownership, race refusal, token checks, and stale recovery.
LOCK_ROOT="$TMP_ROOT/lock-root"
mkdir -p "$LOCK_ROOT/proc/sys/kernel/random" "$LOCK_ROOT/proc/$$" "$LOCK_ROOT/root" "$LOCK_ROOT/tmp"
printf 'lock-boot\n' > "$LOCK_ROOT/proc/sys/kernel/random/boot_id"
printf '1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 4242\n' > "$LOCK_ROOT/proc/$$/stat"
VPN_UI_UPDATE_SOURCE_ONLY=1 PREMIER_ROUTER_HOST_TEST=1 VPN_UI_ROOT_PREFIX="$LOCK_ROOT" \
  VPN_UI_UPDATE_LIB="$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  sh -c '
    . "$1"
    lock_acquire token-one
    ! lock_acquire token-two
    ! lock_release wrong-token
    lock_release token-one
    lock_release token-one || true
    [ ! -d "$LOCK_DIR" ]
    mkdir -p "$LOCK_DIR"
    printf "token=stale\npid=999999\nboot_id=lock-boot\nstart_id=99\n" > "$LOCK_DIR/owner"
    lock_acquire token-after-stale
    lock_release token-after-stale
    mkdir -p "$LOCK_DIR"
    printf "token=old-boot\npid=%s\nboot_id=previous-boot\nstart_id=4242\n" "$$" > "$LOCK_DIR/owner"
    lock_acquire token-after-boot-change
    ! lock_release old-boot
    lock_release token-after-boot-change
    generated="$(random_token)"
    [ "${#generated}" -eq 64 ]
    case "$generated" in *[!0-9a-f]*) exit 1 ;; esac
  ' sh "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
stage lock-ownership

printf 'Updater v2 commit, rollback, failure injection, quarantine, journal, and lock tests passed\n'
