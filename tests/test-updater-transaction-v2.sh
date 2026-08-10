#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION")"
USIGN_BIN="${TEST_USIGN_BIN:-$(command -v usign || true)}"
[ -x "$USIGN_BIN" ] || { printf 'usign is required for transaction tests\n' >&2; exit 1; }
UCODE_BIN="${TEST_UCODE_BIN:-$(command -v ucode || true)}"
[ -x "$UCODE_BIN" ] || { printf 'ucode is required for adoption-aware transaction tests\n' >&2; exit 1; }
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
IPK_DIR="$TMP_ROOT/ipk" FEED_DIR="$TMP_ROOT/feed" SOURCE_COMMIT="$SOURCE_COMMIT" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/sign-opkg-feed.sh" >/dev/null
IPK_DIR="$TMP_ROOT/ipk" OUT_DIR="$TMP_ROOT/installed-set" SOURCE_COMMIT="$SOURCE_COMMIT" \
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" USIGN_BIN="$USIGN_BIN" \
  "$ROOT_DIR/scripts/stage-installed-package-set.sh"
OUT_ROOT="$TMP_ROOT/stage-root" IPK_DIR="$TMP_ROOT/ipk" FEED_DIR="$TMP_ROOT/feed" \
  INSTALLED_SET_DIR="$TMP_ROOT/installed-set" RELEASE_DIR="$TMP_ROOT/release" \
  SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_DIRTY=false SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  USIGN_BIN="$USIGN_BIN" "$ROOT_DIR/scripts/stage-router-release.sh" >/dev/null
printf '%s\n' "$KEY_ID" > "$TMP_ROOT/release-key-id"

# Build the exact RC5 bootstrap lineage with the ephemeral host-test key. This
# lets the current updater consume transaction metadata emitted by the actual
# d02b3bcd RC5 updater instead of a hand-authored approximation.
RC5_SOURCE_COMMIT='d02b3bcd187a44d366469ed1f37bb1b273e60529'
RC5_SOURCE_DATE_EPOCH='1785839862'
RC5_SOURCE_ROOT="$TMP_ROOT/rc5-source"
RC5_IPK_DIR="$TMP_ROOT/rc5-ipk"
RC5_INSTALLED_SET="$TMP_ROOT/rc5-installed-set"
mkdir -p "$RC5_SOURCE_ROOT"
git -C "$ROOT_DIR" archive "$RC5_SOURCE_COMMIT" | tar -xf - -C "$RC5_SOURCE_ROOT"
SOURCE_COMMIT="$RC5_SOURCE_COMMIT" SOURCE_DIRTY=false \
  SOURCE_DATE_EPOCH="$RC5_SOURCE_DATE_EPOCH" BUILD_DIR="$TMP_ROOT/rc5-build" \
  OUT_DIR="$RC5_IPK_DIR" FEED_DIR="$TMP_ROOT/rc5-feed" \
  "$RC5_SOURCE_ROOT/scripts/build-openwrt-ipks.sh" >/dev/null
IPK_DIR="$RC5_IPK_DIR" OUT_DIR="$RC5_INSTALLED_SET" \
  SOURCE_COMMIT="$RC5_SOURCE_COMMIT" SOURCE_DIRTY=false \
  SOURCE_DATE_EPOCH="$RC5_SOURCE_DATE_EPOCH" USIGN_BIN="$USIGN_BIN" \
  "$RC5_SOURCE_ROOT/scripts/stage-installed-package-set.sh" >/dev/null 2>&1
RC5_TEST_MANIFEST_SHA="$(sha256sum "$RC5_INSTALLED_SET/installed-manifest.json" | awk '{print $1}')"
RC5_TEST_SIGNATURE_SHA="$(sha256sum "$RC5_INSTALLED_SET/installed-manifest.json.sig" | awk '{print $1}')"
RC5_TEST_KEY_FINGERPRINT="$($USIGN_BIN -F -p "$PUBLIC")"
RC5_TEST_UPDATER_SHA="$(sha256sum "$RC5_SOURCE_ROOT/luci-vpn-ui/files/usr/sbin/vpn-ui-update" | awk '{print $1}')"
RC5_TEST_UPDATE_LIB_SHA="$(sha256sum "$RC5_SOURCE_ROOT/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" | awk '{print $1}')"
RC5_TEST_VALIDATOR_SHA="$(sha256sum "$RC5_SOURCE_ROOT/luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator" | awk '{print $1}')"
export RC5_SOURCE_COMMIT RC5_SOURCE_DATE_EPOCH RC5_SOURCE_ROOT RC5_IPK_DIR RC5_INSTALLED_SET
export RC5_TEST_MANIFEST_SHA RC5_TEST_SIGNATURE_SHA RC5_TEST_KEY_FINGERPRINT
export RC5_TEST_UPDATER_SHA RC5_TEST_UPDATE_LIB_SHA RC5_TEST_VALIDATOR_SHA

FAKE_OPKG="$TMP_ROOT/opkg"
FAKE_SYSUPGRADE="$TMP_ROOT/sysupgrade"
cat > "$FAKE_OPKG" <<'EOF'
#!/bin/sh
set -eu
db="$FAKE_ROOT/var/lib/fake-opkg"
mkdir -p "$db" "$FAKE_ROOT/usr/lib/opkg/info"
write_status() {
  local record status_pkg version
  : > "$FAKE_ROOT/usr/lib/opkg/status"
  for record in "$db"/*; do
    [ -f "$record" ] || continue
    status_pkg="$(basename "$record")"
    version="$(cat "$record")"
    printf 'Package: %s\nVersion: %s\nStatus: install user installed\n\n' "$status_pkg" "$version" >> "$FAKE_ROOT/usr/lib/opkg/status"
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
    for control_member in conffiles preinst prerm postrm; do
      if tar -xzOf "$ipk" ./control.tar.gz | tar -tzf - | grep -Fqx "./$control_member"; then
        tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - "./$control_member" \
          > "$FAKE_ROOT/usr/lib/opkg/info/$pkg.$control_member"
        case "$control_member" in conffiles) chmod 644 "$FAKE_ROOT/usr/lib/opkg/info/$pkg.$control_member" ;; *) chmod 755 "$FAKE_ROOT/usr/lib/opkg/info/$pkg.$control_member" ;; esac
      fi
    done
    write_status
    if [ "$pkg" = premier-router-core ] && [ "${FAKE_OPKG_KEEP_REAL_VPN_UI:-0}" = 1 ]; then
      vpn_ui="$FAKE_ROOT/usr/sbin/vpn-ui"
      vpn_ui_host="$vpn_ui.host-test"
      {
        printf '#!/bin/sh\n'
        sed '1d' "$vpn_ui"
      } > "$vpn_ui_host"
      mv "$vpn_ui_host" "$vpn_ui"
      chmod 755 "$vpn_ui"
    elif [ "$pkg" = premier-router-core ]; then
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
    VPN_UI_TEST_RC5_SOURCE_DATE_EPOCH="$RC5_SOURCE_DATE_EPOCH" \
    VPN_UI_TEST_RC5_SIGNING_KEY_ID="$KEY_ID" \
    VPN_UI_TEST_RC5_SIGNING_KEY_FINGERPRINT="$RC5_TEST_KEY_FINGERPRINT" \
    VPN_UI_TEST_RC5_MANIFEST_SHA256="$RC5_TEST_MANIFEST_SHA" \
    VPN_UI_TEST_RC5_SIGNATURE_SHA256="$RC5_TEST_SIGNATURE_SHA" \
    VPN_UI_TEST_RC5_UPDATER_SHA256="$RC5_TEST_UPDATER_SHA" \
    VPN_UI_TEST_RC5_UPDATE_LIB_SHA256="$RC5_TEST_UPDATE_LIB_SHA" \
    VPN_UI_TEST_RC5_VALIDATOR_SHA256="$RC5_TEST_VALIDATOR_SHA" \
    VPN_UI_UPDATE_RESTART_CRON=0 \
    sh "$TMP_ROOT/release/router-update-supervisor" "$@"
}

run_supervisor_env() {
  command="$1"
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
    VPN_UI_TEST_RC5_SOURCE_DATE_EPOCH="$RC5_SOURCE_DATE_EPOCH" \
    VPN_UI_TEST_RC5_SIGNING_KEY_ID="$KEY_ID" \
    VPN_UI_TEST_RC5_SIGNING_KEY_FINGERPRINT="$RC5_TEST_KEY_FINGERPRINT" \
    VPN_UI_TEST_RC5_MANIFEST_SHA256="$RC5_TEST_MANIFEST_SHA" \
    VPN_UI_TEST_RC5_SIGNATURE_SHA256="$RC5_TEST_SIGNATURE_SHA" \
    VPN_UI_TEST_RC5_UPDATER_SHA256="$RC5_TEST_UPDATER_SHA" \
    VPN_UI_TEST_RC5_UPDATE_LIB_SHA256="$RC5_TEST_UPDATE_LIB_SHA" \
    VPN_UI_TEST_RC5_VALIDATOR_SHA256="$RC5_TEST_VALIDATOR_SHA" \
    VPN_UI_UPDATE_RESTART_CRON=0 "$@" \
    sh "$TMP_ROOT/release/router-update-supervisor" "$command"
}

seed_rc5_source() {
  local package source_manifest source_signature source_hash source_dir
  reset_source 0.7.11-rc.5
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    FAKE_ROOT="$FAKE_ROOT" "$FAKE_OPKG" install --force-reinstall \
      "$RC5_IPK_DIR/${package}_0.7.11~rc5-1_all.ipk"
  done
  source_manifest="$RC5_INSTALLED_SET/installed-manifest.json"
  source_signature="$RC5_INSTALLED_SET/installed-manifest.json.sig"
  source_hash="$(sha256sum "$source_manifest" | awk '{print $1}')"
  source_dir="$FAKE_ROOT/root/premier-router-updates/known-good/$source_hash"
  mkdir -p "$source_dir" "$FAKE_ROOT/etc/premier-router"
  cp "$source_manifest" "$FAKE_ROOT/etc/premier-router/installed-manifest.json"
  cp "$source_signature" "$FAKE_ROOT/etc/premier-router/installed-manifest.json.sig"
  cp "$source_manifest" "$source_dir/router-release-manifest.json"
  cp "$source_signature" "$source_dir/router-release-manifest.json.sig"
  cp "$RC5_INSTALLED_SET/router-candidate-validator" "$source_dir/router-candidate-validator"
  chmod 755 "$source_dir/router-candidate-validator"
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    cp "$RC5_IPK_DIR/${package}_0.7.11~rc5-1_all.ipk" "$source_dir/"
  done
}

run_update_from_rc5() {
  env PREMIER_ROUTER_HOST_TEST=1 FAKE_ROOT="$FAKE_ROOT" \
    PR_USIGN_BIN="$USIGN_BIN" \
    PR_OPENWRT_RELEASE_FILE="$FAKE_ROOT/etc/openwrt_release" \
    VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_UPDATE_LIB="$RC5_SOURCE_ROOT/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
    VPN_UI_UPDATE_SELF="$RC5_SOURCE_ROOT/luci-vpn-ui/files/usr/sbin/vpn-ui-update" \
    VPN_UI_RELEASE_PUBLIC_KEY="$PUBLIC" \
    VPN_UI_RELEASE_KEY_ID_FILE="$TMP_ROOT/release-key-id" \
    VPN_UI_OPKG_BIN="$FAKE_OPKG" VPN_UI_SYSUPGRADE_BIN="$FAKE_SYSUPGRADE" \
    VPN_UI_UPDATE_RESTART_CRON=0 \
    sh "$RC5_SOURCE_ROOT/luci-vpn-ui/files/usr/sbin/vpn-ui-update" apply-local \
      "$TMP_ROOT/release" "$TMP_ROOT/release/router-release-manifest.json" \
      "$TMP_ROOT/release/router-release-manifest.json.sig" manual no
}

probe_exact_space_requirements() {
  reset_source 0.7.10
  if run_update manual VPN_UI_TEST_PERSISTENT_FREE_BYTES=0 VPN_UI_TEST_TMP_FREE_BYTES=0 \
    > "$TMP_ROOT/space-probe.log" 2> "$TMP_ROOT/space-probe.err"; then
    printf 'zero-byte storage probe unexpectedly succeeded\n' >&2
    exit 1
  fi
  transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
  reservation="$FAKE_ROOT/root/premier-router-updates/$transaction/reservation.json"
  PERSISTENT_REQUIRED_BYTES="$(jq -er .persistent_required_bytes "$reservation")"
  TMP_REQUIRED_BYTES="$(jq -er .temporary_required_bytes "$reservation")"
  export PERSISTENT_REQUIRED_BYTES TMP_REQUIRED_BYTES
  [ "$PERSISTENT_REQUIRED_BYTES" -ge 1680384 ]
  [ "$TMP_REQUIRED_BYTES" -ge 1131520 ]
  [ "$(jq -r .persistent_free_bytes "$reservation")" -eq 0 ]
  [ "$(jq -r .temporary_free_bytes "$reservation")" -eq 0 ]
  [ "$(jq -r .state "$FAKE_ROOT/root/premier-router-updates/$transaction/state.json")" = failed_before_mutation ]
  [ "$(jq -r .mutation_started "$FAKE_ROOT/root/premier-router-updates/$transaction/state.json")" = false ]
  [ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.10 ]
}

run_exact_space_case() {
  label="$1"
  persistent_free="$2"
  temporary_free="$3"
  expected="$4"
  reset_source 0.7.10
  if run_update manual \
    "VPN_UI_TEST_PERSISTENT_FREE_BYTES=$persistent_free" \
    "VPN_UI_TEST_TMP_FREE_BYTES=$temporary_free" \
    > "$TMP_ROOT/space-$label.log" 2> "$TMP_ROOT/space-$label.err"; then
    actual=pass
  else
    actual=fail
  fi
  [ "$actual" = "$expected" ] || {
    printf 'exact storage boundary %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    cat "$TMP_ROOT/space-$label.err" >&2
    exit 1
  }
  transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
  reservation="$FAKE_ROOT/root/premier-router-updates/$transaction/reservation.json"
  [ "$(jq -r .persistent_free_bytes "$reservation")" -eq "$persistent_free" ]
  [ "$(jq -r .temporary_free_bytes "$reservation")" -eq "$temporary_free" ]
  if [ "$expected" = pass ]; then
    [ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = "$APP_VERSION" ]
  else
    journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
    [ "$(jq -r .state "$journal")" = failed_before_mutation ]
    [ "$(jq -r .mutation_started "$journal")" = false ]
    [ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.10 ]
  fi
}

probe_exact_space_requirements
run_exact_space_case persistent-below "$((PERSISTENT_REQUIRED_BYTES - 1))" "$TMP_REQUIRED_BYTES" fail
run_exact_space_case exact-both "$PERSISTENT_REQUIRED_BYTES" "$TMP_REQUIRED_BYTES" pass
run_exact_space_case persistent-above "$((PERSISTENT_REQUIRED_BYTES + 1))" "$TMP_REQUIRED_BYTES" pass
run_exact_space_case temporary-below "$PERSISTENT_REQUIRED_BYTES" "$((TMP_REQUIRED_BYTES - 1))" fail
run_exact_space_case temporary-above "$PERSISTENT_REQUIRED_BYTES" "$((TMP_REQUIRED_BYTES + 1))" pass
stage exact-byte-storage-boundaries

# Real downloads are created with curl's default non-executable mode.  Keep the
# fixture honest and require the updater to promote only the verified validator.
chmod 600 "$TMP_ROOT/release/router-candidate-validator"
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
[ -x "$(find "$FAKE_ROOT/root/premier-router-updates/known-good" -type f \
  -name router-candidate-validator -print -quit)" ]
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
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = "$APP_VERSION" ]
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

# RC5 wrote no protected-validation pair. The RC6 reboot path may bridge only
# the exact signed bootstrap lineage and must materialize the current pair
# after proving the stable protected state is unchanged.
prepare_rc5_reboot_transaction() {
  seed_rc5_source
  run_update_from_rc5 > "$TMP_ROOT/rc5-bridge-apply.log" \
    2> "$TMP_ROOT/rc5-bridge-apply.err"
  RC5_TRANSACTION="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
  RC5_TRANSACTION_DIR="$FAKE_ROOT/root/premier-router-updates/$RC5_TRANSACTION"
  RC5_JOURNAL="$RC5_TRANSACTION_DIR/state.json"
  RC5_ROLLBACK="$RC5_TRANSACTION_DIR/rollback"
  export RC5_TRANSACTION RC5_TRANSACTION_DIR RC5_JOURNAL RC5_ROLLBACK
  [ "$(jq -r .state "$RC5_JOURNAL")" = committed_pending_reboot_validation ]
  [ ! -e "$RC5_ROLLBACK/protected-validation.paths.list" ]
  [ ! -e "$RC5_ROLLBACK/protected-validation-source.fingerprint" ]
  [ "$(sha256sum "$RC5_ROLLBACK/source-supervisor" | awk '{print $1}')" = "$RC5_TEST_UPDATER_SHA" ]
  [ "$(sha256sum "$RC5_ROLLBACK/update-lib.sh" | awk '{print $1}')" = "$RC5_TEST_UPDATE_LIB_SHA" ]
  printf 'boot-after-rc5-bridge\n' > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
}

expect_rc5_bridge_rejected() {
  local label="$1" state
  run_supervisor_env recover FAKE_OPKG_KEEP_REAL_VPN_UI=1 \
    > "$TMP_ROOT/rc5-bridge-$label.log" 2> "$TMP_ROOT/rc5-bridge-$label.err" || true
  state="$(jq -r .state "$RC5_JOURNAL")"
  [ "$state" != committed ] || {
    printf 'RC5 reboot bridge accepted negative case: %s\n' "$label" >&2
    exit 1
  }
}

prepare_rc5_reboot_transaction
cat > "$TMP_ROOT/rc5-protected.paths.expected" <<'EOF'
/etc/config
/etc/crontabs/root
/etc/vpn-ui-update.conf
/etc/xray
/usr/lib/opkg/info/luci-app-premier-router.control
/usr/lib/opkg/info/luci-app-premier-router.list
/usr/lib/opkg/info/luci-app-premier-router.postrm
/usr/lib/opkg/info/premier-router-core.conffiles
/usr/lib/opkg/info/premier-router-core.control
/usr/lib/opkg/info/premier-router-core.list
/usr/lib/opkg/info/premier-router-core.postrm
/usr/lib/opkg/info/premier-router-setup.control
/usr/lib/opkg/info/premier-router-setup.list
/usr/lib/opkg/info/premier-router-setup.postrm
/usr/lib/opkg/info/premier-router-setup.preinst
/usr/lib/opkg/status
EOF
cmp -s "$TMP_ROOT/rc5-protected.paths.expected" "$RC5_ROLLBACK/protected.paths.list"
run_supervisor recover
[ "$(jq -r .state "$RC5_JOURNAL")" = committed ]
[ -s "$RC5_ROLLBACK/protected-validation.paths.list" ]
[ -s "$RC5_ROLLBACK/protected-validation-source.fingerprint" ]
grep -Fqx '/etc/premier-router/xray-ownership.json' \
  "$RC5_ROLLBACK/protected-validation.paths.list"
grep -Fqx 'missing - - /etc/premier-router/xray-ownership.json' \
  "$RC5_ROLLBACK/protected-validation-source.fingerprint"
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
stage exact-rc5-reboot-metadata-bridge

prepare_rc5_reboot_transaction
printf 'tampered config\n' >> "$FAKE_ROOT/etc/config/network"
expect_rc5_bridge_rejected protected-config-tamper

prepare_rc5_reboot_transaction
grep -Fvx '/etc/crontabs/root' "$RC5_ROLLBACK/protected.paths.list" \
  > "$RC5_ROLLBACK/protected.paths.list.tmp"
mv "$RC5_ROLLBACK/protected.paths.list.tmp" "$RC5_ROLLBACK/protected.paths.list"
expect_rc5_bridge_rejected protected-list-tamper

prepare_rc5_reboot_transaction
printf 'missing - - /etc/not-authorized\n' >> "$RC5_ROLLBACK/protected-source.fingerprint"
expect_rc5_bridge_rejected protected-fingerprint-tamper

prepare_rc5_reboot_transaction
jq '.source_app_version = "0.7.11-rc.4"' "$RC5_JOURNAL" > "$RC5_JOURNAL.tmp"
mv "$RC5_JOURNAL.tmp" "$RC5_JOURNAL"
expect_rc5_bridge_rejected wrong-source-tuple

prepare_rc5_reboot_transaction
rm -f "$RC5_ROLLBACK/source-known-good-path"
expect_rc5_bridge_rejected missing-source-evidence

prepare_rc5_reboot_transaction
rm -f "$RC5_ROLLBACK/protected.sha256"
expect_rc5_bridge_rejected missing-protected-hashes

prepare_rc5_reboot_transaction
cp "$TMP_ROOT/rc5-protected.paths.expected" \
  "$RC5_ROLLBACK/protected-validation.paths.list"
expect_rc5_bridge_rejected partial-new-metadata

prepare_rc5_reboot_transaction
printf '{}\n' > "$FAKE_ROOT/etc/premier-router/xray-ownership.json"
expect_rc5_bridge_rejected ownership-file-present

prepare_rc5_reboot_transaction
ln -s ../config/network "$FAKE_ROOT/etc/premier-router/xray-ownership.json"
expect_rc5_bridge_rejected ownership-symlink-present

prepare_rc5_reboot_transaction
printf '\n# tampered\n' >> "$RC5_ROLLBACK/source-supervisor"
expect_rc5_bridge_rejected source-supervisor-tamper

prepare_rc5_reboot_transaction
printf '\n' >> "$RC5_ROLLBACK/source-manifest.json.sig"
expect_rc5_bridge_rejected source-signature-tamper

prepare_rc5_reboot_transaction
printf '\n' >> "$RC5_ROLLBACK/source-manifest.json"
expect_rc5_bridge_rejected source-manifest-tamper

prepare_rc5_reboot_transaction
source_known_good="$(cat "$RC5_ROLLBACK/source-known-good-path")"
printf '\n' >> "$source_known_good/premier-router-core_0.7.11~rc5-1_all.ipk"
expect_rc5_bridge_rejected cached-core-ipk-tamper
stage rc5-reboot-bridge-negative-cases

# A Valera-shaped manual configuration must survive candidate and changed-boot
# validation byte-for-byte.  Ownership may be established only after the
# protocol-2 journal reaches committed, and rollback must restore its absence.
reset_source 0.7.10
mkdir -p "$FAKE_ROOT/etc/xray"
cp "$ROOT_DIR/tests/fixtures/xray/valera-manual-config.json" \
  "$FAKE_ROOT/etc/xray/config.json"
manual_config_sha="$(sha256sum "$FAKE_ROOT/etc/xray/config.json" | awk '{print $1}')"
fake_xray="$TMP_ROOT/fake-xray"
cat > "$fake_xray" <<'EOF'
#!/bin/sh
[ "$1" = run ] && [ "$2" = -test ] && [ "$3" = -config ] &&
  jq -e . "$4" >/dev/null 2>&1
EOF
chmod 755 "$fake_xray"
manual_env() {
  env PREMIER_ROUTER_HOST_TEST=1 VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_TEST_ACTIVE_XRAY_CONFIG=/etc/xray/config.json \
    VPN_UI_XRAY_BIN="$fake_xray" \
    VPN_UI_XRAY_OVERLAY_HELPER="$FAKE_ROOT/usr/libexec/premier-router/xray-overlay.uc" \
    VPN_UI_UCODE_BIN="$UCODE_BIN" \
    "$FAKE_ROOT/usr/sbin/vpn-ui" "$@"
}
if ! run_update manual \
  FAKE_OPKG_KEEP_REAL_VPN_UI=1 \
  VPN_UI_TEST_ACTIVE_XRAY_CONFIG=/etc/xray/config.json \
  VPN_UI_XRAY_BIN="$fake_xray" VPN_UI_UCODE_BIN="$UCODE_BIN" \
  > "$TMP_ROOT/manual-candidate.log" 2> "$TMP_ROOT/manual-candidate.err"; then
  cat "$TMP_ROOT/manual-candidate.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  exit 1
fi
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = committed_pending_reboot_validation ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/config.json" | awk '{print $1}')" = "$manual_config_sha" ]
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
jq -e '.ok == true and
  (.warnings | index("compatible manual Xray configuration awaits explicit post-commit adoption") != null)' \
  "$FAKE_ROOT/root/premier-router-updates/$transaction/validator-candidate.json" >/dev/null
manual_env adoption-preview > "$TMP_ROOT/manual-preview.json"
jq -e '.ok == true and .adoption.analysis.domain_count == 166 and
  .adoption.analysis.ip_count == 14' "$TMP_ROOT/manual-preview.json" >/dev/null
manual_env adoption-confirm /etc/xray/config.json \
  "$(jq -r .adoption.config_sha256 "$TMP_ROOT/manual-preview.json")" \
  "$(jq -r .adoption.analysis.domain_rule_index "$TMP_ROOT/manual-preview.json")" \
  "$(jq -r .adoption.analysis.ip_rule_index "$TMP_ROOT/manual-preview.json")" \
  > "$TMP_ROOT/manual-pending-adoption.json"
jq -e '.ok == false and (.error | contains("supervised reboot validation"))' \
  "$TMP_ROOT/manual-pending-adoption.json" >/dev/null
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
printf 'boot-after-manual-candidate\n' > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
run_supervisor_env recover \
  FAKE_OPKG_KEEP_REAL_VPN_UI=1 \
  VPN_UI_TEST_ACTIVE_XRAY_CONFIG=/etc/xray/config.json \
  VPN_UI_XRAY_BIN="$fake_xray" VPN_UI_UCODE_BIN="$UCODE_BIN"
[ "$(jq -r .state "$journal")" = committed ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/config.json" | awk '{print $1}')" = "$manual_config_sha" ]
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
manual_env adoption-confirm /etc/xray/config.json \
  "$(jq -r .adoption.config_sha256 "$TMP_ROOT/manual-preview.json")" \
  "$(jq -r .adoption.analysis.domain_rule_index "$TMP_ROOT/manual-preview.json")" \
  "$(jq -r .adoption.analysis.ip_rule_index "$TMP_ROOT/manual-preview.json")" \
  > "$TMP_ROOT/manual-adopted.json"
jq -e '.ok == true and .ownership.mode == "adopted-overlay"' \
  "$TMP_ROOT/manual-adopted.json" >/dev/null
[ -s "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
run_supervisor rollback "$transaction"
[ "$(jq -r .state "$journal")" = rolled_back ]
[ "$(sha256sum "$FAKE_ROOT/etc/xray/config.json" | awk '{print $1}')" = "$manual_config_sha" ]
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
stage adoption-aware-candidate-reboot-and-protected-rollback

reset_source 0.7.10
if ! run_update manual > "$TMP_ROOT/success.log" 2> "$TMP_ROOT/success.err"; then
  cat "$TMP_ROOT/success.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  find "$FAKE_ROOT/root/premier-router-updates" -name state.json -exec cat {} \; >&2 2>/dev/null || true
  exit 1
fi
stage 0710-applied
grep -q "Router UI $APP_VERSION committed" "$TMP_ROOT/success.log"
[ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = "$APP_VERSION" ]
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
