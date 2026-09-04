#!/bin/sh
set -eu
[ -z "${ROUTER_UI_TIER0_GUARD_LOG:-}" ] || { printf 'package-integration-test:%s\n' "${0##*/}" >> "$ROUTER_UI_TIER0_GUARD_LOG"; exit 97; }
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER_SOURCE="$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update"
if grep -Eq 'sort([[:space:]][^[:space:]]+)*[[:space:]]-o([[:space:]]|$)' "$UPDATER_SOURCE"; then
  printf 'updater uses unsupported target BusyBox sort output mode\n' >&2
  exit 1
fi
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

# RC5's exact vpn-summary helper discovers Xray through PATH. Keep that source
# validation hermetic on hosts that do not have a router Xray binary installed.
HOST_TEST_BIN="$TMP_ROOT/host-test-bin"
fake_xray="$HOST_TEST_BIN/xray"
mkdir -p "$HOST_TEST_BIN"
cat > "$fake_xray" <<'EOF'
#!/bin/sh
[ "$1" = run ] && [ "$2" = -test ] && [ "$3" = -config ] &&
  jq -e . "$4" >/dev/null 2>&1
EOF
chmod 755 "$fake_xray"
cat > "$HOST_TEST_BIN/jsonfilter" <<'EOF'
#!/bin/sh
set -eu
input=""
expression=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i) input="$2"; shift 2 ;;
    -e) expression="$2"; shift 2 ;;
    *) exit 1 ;;
  esac
done
[ -n "$input" ] && [ -n "$expression" ] || exit 1
expression="${expression#@}"
jq -r "$expression | select(. != null) |
  if type == \"boolean\" then tostring else . end" "$input"
EOF
chmod 755 "$HOST_TEST_BIN/jsonfilter"
PATH="$HOST_TEST_BIN:$PATH"
export PATH

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
    upgrade=0
    [ ! -f "$db/$pkg" ] || upgrade=1
    package_script="$FAKE_ROOT/tmp/$pkg.package-script"
    if [ "$pkg" = premier-router-core ] &&
      tar -xzOf "$ipk" ./control.tar.gz | tar -tzf - | grep -Fqx ./preinst; then
      tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./preinst > "$package_script"
      if grep -Fq PREMIER_ROUTER_PACKAGE_ROOT "$package_script"; then
        PREMIER_ROUTER_HOST_TEST=1 PREMIER_ROUTER_PACKAGE_ROOT="$FAKE_ROOT" \
          PKG_UPGRADE="$upgrade" sh "$package_script"
      fi
    fi
    if [ "$pkg" = premier-router-core ] && [ "$upgrade" = 1 ] &&
      [ -f "$FAKE_ROOT/usr/lib/opkg/info/$pkg.postrm" ]; then
      old_postrm="$FAKE_ROOT/usr/lib/opkg/info/$pkg.postrm"
      if grep -Fq PREMIER_ROUTER_PACKAGE_ROOT "$old_postrm"; then
        PREMIER_ROUTER_HOST_TEST=1 PREMIER_ROUTER_PACKAGE_ROOT="$FAKE_ROOT" \
          PKG_UPGRADE=0 sh "$old_postrm" remove
      elif [ -f "$FAKE_ROOT/etc/crontabs/root" ]; then
        awk 'index($0, "/usr/sbin/vpn-ui auto-tick") == 0 &&
          index($0, "/usr/sbin/vpn-ui-update auto") == 0 { print }' \
          "$FAKE_ROOT/etc/crontabs/root" > "$FAKE_ROOT/etc/crontabs/root.old-postrm"
        mv "$FAKE_ROOT/etc/crontabs/root.old-postrm" "$FAKE_ROOT/etc/crontabs/root"
      fi
    fi
    rm -f "$FAKE_ROOT/usr/lib/opkg/info/$pkg.control" \
      "$FAKE_ROOT/usr/lib/opkg/info/$pkg.list" \
      "$FAKE_ROOT/usr/lib/opkg/info/$pkg.conffiles" \
      "$FAKE_ROOT/usr/lib/opkg/info/$pkg.preinst" \
      "$FAKE_ROOT/usr/lib/opkg/info/$pkg.prerm" \
      "$FAKE_ROOT/usr/lib/opkg/info/$pkg.postinst" \
      "$FAKE_ROOT/usr/lib/opkg/info/$pkg.postrm"
    keep="$FAKE_ROOT/tmp/conffile.keep"
    metadata_keep="$FAKE_ROOT/tmp/premier-router-metadata.keep"
    transparent_keep="$FAKE_ROOT/tmp/transparent-init.keep"
    if [ "$pkg" = premier-router-core ] &&
      [ -f "$FAKE_ROOT/etc/init.d/xray-transparent" ] &&
      tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./conffiles |
        grep -Fqx /etc/init.d/xray-transparent; then
      cp -p "$FAKE_ROOT/etc/init.d/xray-transparent" "$transparent_keep"
    fi
    [ ! -f "$FAKE_ROOT/etc/vpn-ui-update.conf" ] || cp -p "$FAKE_ROOT/etc/vpn-ui-update.conf" "$keep"
    [ ! -f "$FAKE_ROOT/etc/config/premier_router" ] ||
      cp -p "$FAKE_ROOT/etc/config/premier_router" "$metadata_keep"
    tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$FAKE_ROOT"
    if [ -f "$transparent_keep" ]; then
      if ! cmp -s "$transparent_keep" "$FAKE_ROOT/etc/init.d/xray-transparent"; then
        cp -p "$FAKE_ROOT/etc/init.d/xray-transparent" \
          "$FAKE_ROOT/etc/init.d/xray-transparent-opkg"
        cp -p "$transparent_keep" "$FAKE_ROOT/etc/init.d/xray-transparent"
      fi
      rm -f "$transparent_keep"
    fi
    if [ -f "$keep" ]; then
      [ "$pkg" != premier-router-core ] ||
        cp -p "$FAKE_ROOT/etc/vpn-ui-update.conf" "$FAKE_ROOT/etc/vpn-ui-update.conf-opkg"
      cp -p "$keep" "$FAKE_ROOT/etc/vpn-ui-update.conf"
      rm -f "$keep"
    fi
    if [ -f "$metadata_keep" ]; then
      [ "$pkg" != premier-router-core ] ||
        cp -p "$FAKE_ROOT/etc/config/premier_router" "$FAKE_ROOT/etc/config/premier_router-opkg"
      cp -p "$metadata_keep" "$FAKE_ROOT/etc/config/premier_router"
      rm -f "$metadata_keep"
    fi
    printf '%s\n' "$version" > "$db/$pkg"
    printf '%s\n' "$control" > "$FAKE_ROOT/usr/lib/opkg/info/$pkg.control"
    tar -xzOf "$ipk" ./data.tar.gz | tar -tzf - > "$FAKE_ROOT/usr/lib/opkg/info/$pkg.list"
    for control_member in conffiles preinst prerm postinst postrm; do
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
case "${1:-}" in
  check|vpn-summary) printf '{"ok":true}\n' ;;
  *) exit 1 ;;
esac
EOS
      chmod 755 "$FAKE_ROOT/usr/sbin/vpn-ui"
    fi
    if [ "$pkg" = premier-router-core ] && [ "$upgrade" = 0 ]; then
      cat > "$FAKE_ROOT/etc/config/premier_router" <<'EOS'
config metadata 'router'
	option router_id 'pr-0123456789abcdef0123456789abcdef'
	option install_method 'manual-ipk-install'
	option install_source 'package-first-local-ipk'
	option installed_at '2026-08-15T12:00:00Z'
	option support_level 'self-managed'
	option registration_state 'local-only'
	option direct_rules_channel 'stable'
	option support_visible '1'
	option support_tailnet_enabled '0'
	option footer_enabled '1'
	option footer_mode 'compact'
	option prepared_by_owner '0'
	option sealed '0'
EOS
      if [ "${FAKE_OPKG_TAMPER_FIRST_INSTALL_METADATA:-0}" = 1 ]; then
        printf '%s\n' "\toption unexpected 'tampered'" >> "$FAKE_ROOT/etc/config/premier_router"
      fi
      chmod "${FAKE_OPKG_FIRST_INSTALL_METADATA_MODE:-600}" \
        "$FAKE_ROOT/etc/config/premier_router"
      if [ "${FAKE_OPKG_ADD_UNAUTHORIZED_CONFIG:-0}" = 1 ]; then
        printf '%s\n' 'unauthorized protected addition' > "$FAKE_ROOT/etc/config/not-authorized"
      fi
    fi
    if [ "$pkg" = premier-router-core ] &&
      tar -xzOf "$ipk" ./control.tar.gz | tar -tzf - | grep -Fqx ./postinst; then
      tar -xzOf "$ipk" ./control.tar.gz | tar -xzOf - ./postinst > "$package_script"
      if grep -Fq PREMIER_ROUTER_PACKAGE_ROOT "$package_script"; then
        recovery_init="$FAKE_ROOT/etc/init.d/premier-router-update-recovery"
        recovery_saved="$FAKE_ROOT/tmp/premier-router-update-recovery.packaged"
        recovery_marker="$FAKE_ROOT/tmp/premier-router-update-recovery.enable-called"
        [ -f "$recovery_init" ] && [ ! -L "$recovery_init" ] || exit 65
        recovery_sha="$(sha256sum "$recovery_init" | awk '{ print $1 }')"
        rm -f "$recovery_saved" "$recovery_marker"
        mv "$recovery_init" "$recovery_saved"
        cat > "$recovery_init" <<'EOS'
#!/bin/sh
set -eu
[ "${1:-}" = enable ]
printf '%s\n' "$1" > "$FAKE_ROOT/tmp/premier-router-update-recovery.enable-called"
EOS
        chmod 755 "$recovery_init"
        postinst_rc=0
        PREMIER_ROUTER_HOST_TEST=1 PREMIER_ROUTER_PACKAGE_ROOT="$FAKE_ROOT" \
          PKG_UPGRADE=0 sh "$package_script" configure || postinst_rc=$?
        rm -f "$recovery_init"
        mv "$recovery_saved" "$recovery_init"
        [ -f "$recovery_init" ] && [ ! -L "$recovery_init" ] &&
          [ -x "$recovery_init" ] || exit 66
        [ "$(sha256sum "$recovery_init" | awk '{ print $1 }')" = "$recovery_sha" ] || exit 67
        if [ "$postinst_rc" = 0 ]; then
          grep -Fqx enable "$recovery_marker" || exit 68
        fi
        rm -f "$recovery_marker"
        [ "$postinst_rc" = 0 ] || exit "$postinst_rc"
      fi
    fi
    rm -f "$package_script"
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
  if [ "$service" = xray-transparent ]; then
    # Keep a real rc.common init for package preflight. Its kernel execution
    # belongs to the OpenWrt VM gate, not this host's service stubs.
    cp "$ROOT_DIR/luci-vpn-ui/files/etc/init.d/xray-transparent" \
      "$FAKE_ROOT/etc/init.d/$service"
    chmod 755 "$FAKE_ROOT/etc/init.d/$service"
    return 0
  fi
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
  for service in cron rpcd uhttpd xray-transparent premier-router-update-recovery; do
    make_service "$service"
  done
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
  # The retained RC5 base models ImageBuilder's prepare_rootfs result, which
  # removes successful postinst scripts. Runtime fake-opkg installs retain them
  # exactly like OpenWrt opkg so rollback -> second-update is exercised honestly.
  for package in premier-router-core luci-app-premier-router premier-router-setup; do
    rm -f "$FAKE_ROOT/usr/lib/opkg/info/$package.postinst"
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

test_core_package_cron_scripts() {
  local core_ipk control package_root cron before expected signal_bin
  local transparent_sha transparent_metadata source_transparent_sha
  local source_bundle transaction_dir
  core_ipk="$(find "$TMP_ROOT/ipk" -maxdepth 1 -type f \
    -name 'premier-router-core_*_all.ipk' -print -quit)"
  [ -n "$core_ipk" ]
  control="$TMP_ROOT/core-package-control"
  package_root="$TMP_ROOT/core-package-root"
  mkdir -p "$control"
  tar -xzOf "$core_ipk" ./control.tar.gz | tar -xzf - -C "$control"
  for script in preinst postinst postrm; do
    [ -x "$control/$script" ]
    sh -n "$control/$script"
  done

  reset_package_root() {
    rm -rf "$package_root"
    mkdir -p "$package_root/etc/crontabs" "$package_root/etc/init.d" \
      "$package_root/tmp"
    tar -xzOf "$core_ipk" ./data.tar.gz | tar -xzf - -C "$package_root"
    cat > "$package_root/etc/init.d/premier-router-update-recovery" <<'EOF'
#!/bin/sh
[ "${1:-}" = enable ]
EOF
    chmod 755 "$package_root/etc/init.d/premier-router-update-recovery"
  }
  run_package_script() {
    local script="$1" action="${4:-}"
    if [ -n "$action" ]; then
      PREMIER_ROUTER_HOST_TEST=1 PREMIER_ROUTER_PACKAGE_ROOT="$package_root" \
        PREMIER_ROUTER_PRESERVE_CRON="${3:-0}" VPN_UI_UPDATE_RESTART_CRON=0 \
        PKG_UPGRADE="${2:-1}" sh "$control/$script" "$action"
    else
      PREMIER_ROUTER_HOST_TEST=1 PREMIER_ROUTER_PACKAGE_ROOT="$package_root" \
        PREMIER_ROUTER_PRESERVE_CRON="${3:-0}" VPN_UI_UPDATE_RESTART_CRON=0 \
        PKG_UPGRADE="${2:-1}" sh "$control/$script"
    fi
  }

  prepare_package_transaction() {
    local state="$1"
    local transaction=20260815T120000Z-0123456789abcdef
    local transaction_dir="$package_root/root/premier-router-updates/$transaction"
    mkdir -p "$transaction_dir/rollback"
    printf '%s\n' "$transaction" > \
      "$package_root/root/premier-router-updates/active-transaction"
    cat > "$transaction_dir/state.json" <<EOF
{
  "state":"$state",
  "mutation_started":true,
  "fixture":true
}
EOF
  }

  set_package_transaction_state() {
    local state="$1"
    local journal="$package_root/root/premier-router-updates/20260815T120000Z-0123456789abcdef/state.json"
    cat > "$journal" <<EOF
{
  "state":"$state",
  "mutation_started":true,
  "fixture":true
}
EOF
  }

  reset_package_root
  cp "$ROOT_DIR/luci-vpn-ui/files/etc/init.d/xray-transparent" \
    "$package_root/etc/init.d/xray-transparent"
  printf '%s\n' '# source customized init' >> "$package_root/etc/init.d/xray-transparent"
  chmod 711 "$package_root/etc/init.d/xray-transparent"
  transparent_sha="$(sha256sum "$package_root/etc/init.d/xray-transparent" | awk '{ print $1 }')"
  transparent_metadata="$(LC_ALL=C ls -ldn \
    "$package_root/etc/init.d/xray-transparent" | awk '{ print $1 ":" $3 ":" $4 }')"
  prepare_package_transaction applying
  run_package_script preinst 1 1
  printf '%s\n' 'candidate transparent init bytes' > \
    "$package_root/etc/init.d/xray-transparent"
  chmod 755 "$package_root/etc/init.d/xray-transparent"
  set_package_transaction_state rolling_back
  run_package_script postrm 1 0 upgrade
  [ "$(sha256sum "$package_root/etc/init.d/xray-transparent" | awk '{ print $1 }')" = \
    "$transparent_sha" ]
  [ "$(LC_ALL=C ls -ldn "$package_root/etc/init.d/xray-transparent" |
    awk '{ print $1 ":" $3 ":" $4 }')" = "$transparent_metadata" ]

  reset_package_root
  rm -f "$package_root/etc/init.d/xray-transparent"
  prepare_package_transaction applying
  run_package_script preinst 1 1
  printf '%s\n' 'candidate transparent init bytes' > \
    "$package_root/etc/init.d/xray-transparent"
  set_package_transaction_state rolling_back
  run_package_script postrm 1 0 upgrade
  [ ! -e "$package_root/etc/init.d/xray-transparent" ] &&
    [ ! -L "$package_root/etc/init.d/xray-transparent" ]

  reset_package_root
  source_transparent_sha="$(
    tar -xzOf "$core_ipk" ./data.tar.gz |
      tar -xzOf - ./etc/init.d/xray-transparent |
      sha256sum | awk '{ print $1 }'
  )"
  rm -f "$package_root/etc/init.d/xray-transparent"
  prepare_package_transaction applying
  transaction_dir="$package_root/root/premier-router-updates/20260815T120000Z-0123456789abcdef"
  source_bundle="$package_root/root/premier-router-updates/known-good/source-manifest"
  mkdir -p "$source_bundle"
  cp "$core_ipk" "$source_bundle/source-core.ipk"
  printf '%s\n' "$source_bundle" > "$transaction_dir/rollback/source-known-good-path"
  printf '%s\n' 'xray-transparent true false' > "$transaction_dir/rollback/services"
  jq -n --arg sha "$(sha256sum "$source_bundle/source-core.ipk" | awk '{ print $1 }')" \
    '{packages:[{name:"premier-router-core",filename:"source-core.ipk",sha256:$sha}]}' \
    > "$transaction_dir/rollback/source-manifest.json"
  run_package_script preinst 1 1
  grep -Fqx "file $source_transparent_sha" \
    "$transaction_dir/rollback/xray-transparent-prestate/state"
  [ "$(tar -xzOf "$transaction_dir/rollback/xray-transparent-prestate/file.tar.gz" \
    etc/init.d/xray-transparent | sha256sum | awk '{ print $1 }')" = \
    "$source_transparent_sha" ]
  printf '%s\n' 'candidate transparent init bytes' > \
    "$package_root/etc/init.d/xray-transparent"
  set_package_transaction_state rolling_back
  run_package_script postrm 1 0 upgrade
  [ "$(sha256sum "$package_root/etc/init.d/xray-transparent" | awk '{ print $1 }')" = \
    "$source_transparent_sha" ]

  reset_package_root
  cp "$ROOT_DIR/luci-vpn-ui/files/etc/init.d/xray-transparent" \
    "$package_root/etc/init.d/xray-transparent"
  printf '%s\n' '# source customized init' >> "$package_root/etc/init.d/xray-transparent"
  prepare_package_transaction applying
  run_package_script preinst 1 1
  printf '%s\n' 'tampered prestate' > \
    "$package_root/root/premier-router-updates/20260815T120000Z-0123456789abcdef/rollback/xray-transparent-prestate/file.tar.gz"
  printf '%s\n' 'candidate transparent init bytes' > \
    "$package_root/etc/init.d/xray-transparent"
  set_package_transaction_state rolling_back
  if run_package_script postrm 1 0 upgrade >/dev/null 2>&1; then
    printf 'core postrm accepted a tampered transparent-init prestate\n' >&2
    exit 1
  fi
  grep -Fqx 'candidate transparent init bytes' \
    "$package_root/etc/init.d/xray-transparent"

  reset_package_root
  run_package_script preinst 1 1
  cp -p "$package_root/etc/config/premier_router" \
    "$package_root/etc/config/premier_router-opkg"
  cp -p "$package_root/etc/vpn-ui-update.conf" \
    "$package_root/etc/vpn-ui-update.conf-opkg"
  run_package_script postinst 1 1
  [ ! -e "$package_root/etc/config/premier_router-opkg" ]
  [ ! -e "$package_root/etc/vpn-ui-update.conf-opkg" ]

  reset_package_root
  cp -p "$package_root/etc/vpn-ui-update.conf" \
    "$package_root/etc/vpn-ui-update.conf-opkg"
  before="$(sha256sum "$package_root/etc/vpn-ui-update.conf-opkg" | awk '{ print $1 }')"
  run_package_script preinst 1 1
  run_package_script postinst 1 1
  [ "$(sha256sum "$package_root/etc/vpn-ui-update.conf-opkg" | awk '{ print $1 }')" = "$before" ]

  reset_package_root
  run_package_script preinst 1 1
  printf '%s\n' 'tampered candidate conffile artifact' > \
    "$package_root/etc/vpn-ui-update.conf-opkg"
  before="$(sha256sum "$package_root/etc/vpn-ui-update.conf-opkg" | awk '{ print $1 }')"
  if run_package_script postinst 1 1 >/dev/null 2>&1; then
    printf 'core postinst accepted a tampered candidate conffile artifact\n' >&2
    exit 1
  fi
  [ "$(sha256sum "$package_root/etc/vpn-ui-update.conf-opkg" | awk '{ print $1 }')" = "$before" ]

  reset_package_root
  cron="$package_root/etc/crontabs/root"
  printf '%s\n' 'legacy cron bytes must remain exact' > "$cron"
  chmod 640 "$cron"
  before="$(sha256sum "$cron" | awk '{ print $1 }')"
  run_package_script postinst 0 1
  [ "$(sha256sum "$cron" | awk '{ print $1 }')" = "$before" ]

  reset_package_root
  cron="$package_root/etc/crontabs/root"
  printf "AUTO_UPDATE='1'\nAUTO_SCHEDULE='Sunday 04:17'\n" > \
    "$package_root/etc/vpn-ui-update.conf"
  printf '%s\n' \
    '5 1 * * * /usr/bin/operator-job --preserve-exactly' \
    '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' \
    '17 4 * * 0 /usr/sbin/vpn-ui-update auto >/tmp/vpn-ui-auto-update.log 2>&1' \
    > "$cron"
  chmod 640 "$cron"
  run_package_script postinst
  expected="$TMP_ROOT/core-package-existing.expected"
  printf '%s\n' \
    '5 1 * * * /usr/bin/operator-job --preserve-exactly' \
    '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' \
    '17 4 * * 0 /usr/sbin/vpn-ui-update auto >/tmp/vpn-ui-auto-update.log 2>&1' \
    > "$expected"
  cmp -s "$expected" "$cron"
  before="$(sha256sum "$cron" | awk '{ print $1 }')"
  run_package_script postrm 1 0 upgrade
  [ "$(sha256sum "$cron" | awk '{ print $1 }')" = "$before" ]
  run_package_script postrm 0 0 remove
  grep -Fqx '5 1 * * * /usr/bin/operator-job --preserve-exactly' "$cron"
  [ "$(wc -l < "$cron" | tr -d ' ')" = 1 ]

  reset_package_root
  cron="$package_root/etc/crontabs/root"
  printf "AUTO_UPDATE='0'\nAUTO_SCHEDULE='Sunday 04:17'\n" > \
    "$package_root/etc/vpn-ui-update.conf"
  run_package_script postinst
  grep -Fqx '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' "$cron"
  [ "$(wc -l < "$cron" | tr -d ' ')" = 1 ]

  reset_package_root
  cron="$package_root/etc/crontabs/root"
  ln -s /dev/null "$cron"
  if run_package_script postinst >/dev/null 2>&1; then
    printf 'core postinst accepted a symlinked cron file\n' >&2
    exit 1
  fi

  reset_package_root
  cron="$package_root/etc/crontabs/root"
  mkfifo "$cron"
  if run_package_script postinst >/dev/null 2>&1; then
    printf 'core postinst accepted a FIFO cron path\n' >&2
    exit 1
  fi

  reset_package_root
  cron="$package_root/etc/crontabs/root"
  printf '%s\n' 'operator cron bytes must survive an interrupted postinst' > "$cron"
  before="$(sha256sum "$cron" | awk '{ print $1 }')"
  signal_bin="$TMP_ROOT/core-package-signal-bin"
  mkdir -p "$signal_bin"
  cat > "$signal_bin/awk" <<'EOF'
#!/bin/sh
set -eu
"$SIGNAL_TEST_REAL_AWK" "$@"
kill -TERM "$PPID"
exit 0
EOF
  chmod 755 "$signal_bin/awk"
  SIGNAL_TEST_REAL_AWK="$(command -v awk)"
  export SIGNAL_TEST_REAL_AWK
  if (
    PATH="$signal_bin:$PATH"
    export PATH
    run_package_script postinst
  ) >/dev/null 2>&1; then
    printf 'core postinst survived TERM after cron filtering\n' >&2
    exit 1
  fi
  [ "$(sha256sum "$cron" | awk '{ print $1 }')" = "$before" ]
  if find "$package_root/etc/crontabs" -maxdepth 1 \
    -name 'root.new.*' -print | grep -q .; then
    printf 'core postinst left a temporary cron file after TERM\n' >&2
    exit 1
  fi
}

test_core_package_cron_scripts
stage core-package-managed-cron-scripts
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
legacy_cron_sha="$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{print $1}')"
if ! run_update manual > "$TMP_ROOT/070-success.log" 2> "$TMP_ROOT/070-success.err"; then
  cat "$TMP_ROOT/070-success.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  find "$FAKE_ROOT/root/premier-router-updates" -name state.json -exec cat {} \; >&2 2>/dev/null || true
  exit 1
fi
stage 070-applied
[ "$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{print $1}')" = "$legacy_cron_sha" ]
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
[ "$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{print $1}')" = "$legacy_cron_sha" ]

reset_source 0.7.9
legacy_cron_sha="$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{print $1}')"
if ! run_update manual > "$TMP_ROOT/079-success.log" 2> "$TMP_ROOT/079-success.err"; then
  cat "$TMP_ROOT/079-success.err" >&2
  cat "$FAKE_ROOT/tmp/premier-router-update.log" >&2 2>/dev/null || true
  find "$FAKE_ROOT/root/premier-router-updates" -name state.json -exec cat {} \; >&2 2>/dev/null || true
  exit 1
fi
stage 079-applied
[ "$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{print $1}')" = "$legacy_cron_sha" ]
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
[ "$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{print $1}')" = "$legacy_cron_sha" ]
[ ! -d "$FAKE_ROOT/root/premier-router-updates/update.lock" ]
[ ! -e "$FAKE_ROOT/www/luci-static/resources/view/status/include/_35_vpn.js" ]

# RC5 wrote no protected-validation pair. The RC15 reboot path may bridge only
# the exact signed bootstrap lineage and must materialize the current pair
# after proving the stable protected state is unchanged.
prepare_rc5_reboot_transaction() {
  local cron_shape="${1:-existing}"
  local postinst_shape="${2:-absent}"
  local source_setup="${3:-seed}"
  local cron_source="$TMP_ROOT/rc5-source-root.cron"
  local cron_expected="$TMP_ROOT/rc15-expected-root.cron"
  local package postinst_path
  case "$source_setup" in
    seed) seed_rc5_source ;;
    current)
      [ "$(cat "$FAKE_ROOT/usr/share/vpn-ui/version")" = 0.7.11-rc.5 ]
      ;;
    *) printf 'unsupported RC5 source setup: %s\n' "$source_setup" >&2; exit 1 ;;
  esac
  case "$postinst_shape" in
    absent) ;;
    current-retained)
      for package in premier-router-core luci-app-premier-router premier-router-setup; do
        postinst_path="$FAKE_ROOT/usr/lib/opkg/info/$package.postinst"
        [ -f "$postinst_path" ] && [ ! -L "$postinst_path" ] && [ -x "$postinst_path" ]
      done
      ;;
    retained|tampered|wrong-mode|symlink)
      for package in premier-router-core luci-app-premier-router premier-router-setup; do
        postinst_path="$FAKE_ROOT/usr/lib/opkg/info/$package.postinst"
        tar -xzOf "$RC5_IPK_DIR/${package}_0.7.11~rc5-1_all.ipk" ./control.tar.gz |
          tar -xzOf - ./postinst > "$postinst_path"
        chmod 755 "$postinst_path"
      done
      if [ "$postinst_shape" = tampered ]; then
        printf '%s\n' '# unauthenticated retained postinst drift' >> \
          "$FAKE_ROOT/usr/lib/opkg/info/premier-router-core.postinst"
      elif [ "$postinst_shape" = wrong-mode ]; then
        chmod 644 "$FAKE_ROOT/usr/lib/opkg/info/premier-router-core.postinst"
      elif [ "$postinst_shape" = symlink ]; then
        rm -f "$FAKE_ROOT/usr/lib/opkg/info/premier-router-core.postinst"
        ln -s /dev/null "$FAKE_ROOT/usr/lib/opkg/info/premier-router-core.postinst"
      fi
      ;;
    partial)
      package=premier-router-core
      postinst_path="$FAKE_ROOT/usr/lib/opkg/info/$package.postinst"
      tar -xzOf "$RC5_IPK_DIR/${package}_0.7.11~rc5-1_all.ipk" ./control.tar.gz |
        tar -xzOf - ./postinst > "$postinst_path"
      chmod 755 "$postinst_path"
      ;;
    *) printf 'unsupported RC5 postinst fixture: %s\n' "$postinst_shape" >&2; exit 1 ;;
  esac
  case "$cron_shape" in
    existing)
      printf '%s\n' \
        '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' \
        '17 4 * * 0 /usr/sbin/vpn-ui-update auto >/tmp/vpn-ui-auto-update.log 2>&1' \
        >> "$FAKE_ROOT/etc/crontabs/root"
      chmod 600 "$FAKE_ROOT/etc/crontabs/root"
      cp "$FAKE_ROOT/etc/crontabs/root" "$cron_source"
      ;;
    missing)
      rm -f "$FAKE_ROOT/etc/crontabs/root"
      : > "$cron_source"
      ;;
    *) printf 'unsupported RC5 cron fixture: %s\n' "$cron_shape" >&2; exit 1 ;;
  esac
  RC5_SOURCE_CRON_SHAPE="$cron_shape"
  if [ "$cron_shape" = existing ]; then
    RC5_SOURCE_CRON_SHA="$(sha256sum "$cron_source" | awk '{ print $1 }')"
  else
    RC5_SOURCE_CRON_SHA=missing
  fi
  export RC5_SOURCE_CRON_SHAPE RC5_SOURCE_CRON_SHA
  RC5_SOURCE_TRANSPARENT_SHA="$(sha256sum \
    "$FAKE_ROOT/etc/init.d/xray-transparent" | awk '{ print $1 }')"
  RC5_SOURCE_TRANSPARENT_METADATA="$(LC_ALL=C ls -ldn \
    "$FAKE_ROOT/etc/init.d/xray-transparent" |
    awk '{ print $1 ":" $3 ":" $4 }')"
  export RC5_SOURCE_TRANSPARENT_SHA RC5_SOURCE_TRANSPARENT_METADATA
  awk 'index($0, "/usr/sbin/vpn-ui auto-tick") == 0 &&
    index($0, "/usr/sbin/vpn-ui-update auto") == 0 { print }' \
    "$cron_source" > "$cron_expected"
  printf '%s\n' \
    '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' \
    '17 4 * * 0 /usr/sbin/vpn-ui-update auto >/tmp/vpn-ui-auto-update.log 2>&1' \
    >> "$cron_expected"
  run_update_from_rc5 > "$TMP_ROOT/rc5-bridge-apply.log" \
    2> "$TMP_ROOT/rc5-bridge-apply.err"
  [ -f "$FAKE_ROOT/etc/crontabs/root" ] && [ ! -L "$FAKE_ROOT/etc/crontabs/root" ]
  cmp -s "$cron_expected" "$FAKE_ROOT/etc/crontabs/root"
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
  printf '%s\n' /etc/config /etc/crontabs/root /etc/vpn-ui-update.conf /etc/xray |
    LC_ALL=C sort > "$TMP_ROOT/rc5-stable.paths"
  awk '$4 == "/etc/config" || index($4, "/etc/config/") == 1 ||
    $4 == "/etc/crontabs/root" || $4 == "/etc/vpn-ui-update.conf" ||
    $4 == "/etc/xray" || index($4, "/etc/xray/") == 1 { print }' \
    "$RC5_ROLLBACK/protected-source.fingerprint" > "$TMP_ROOT/rc5-stable.source"
  env VPN_UI_UPDATE_SOURCE_ONLY=1 VPN_UI_ROOT_PREFIX="$FAKE_ROOT" \
    VPN_UI_UPDATE_LIB="$TMP_ROOT/release/router-update-lib.sh" \
    sh -c '. "$1"; fingerprint_paths "$2" "$3"' sh \
    "$TMP_ROOT/release/router-update-supervisor" "$TMP_ROOT/rc5-stable.paths" \
    "$TMP_ROOT/rc5-stable.current"
  awk '$4 != "/etc/crontabs/root" { print }' "$TMP_ROOT/rc5-stable.source" \
    > "$TMP_ROOT/rc5-stable-source-without-cron"
  awk '$4 != "/etc/crontabs/root" { print }' "$TMP_ROOT/rc5-stable.current" \
    > "$TMP_ROOT/rc5-stable-current-without-cron"
  cmp -s "$TMP_ROOT/rc5-stable-source-without-cron" \
    "$TMP_ROOT/rc5-stable-current-without-cron" || {
    diff -u "$TMP_ROOT/rc5-stable-source-without-cron" \
      "$TMP_ROOT/rc5-stable-current-without-cron" >&2 || true
    return 1
  }
  cmp -s "$cron_expected" "$FAKE_ROOT/etc/crontabs/root"
  printf 'boot-after-rc5-bridge-%s\n' "$RC5_TRANSACTION" \
    > "$FAKE_ROOT/proc/sys/kernel/random/boot_id"
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

expect_rc5_target_drift_rolled_back() {
  local label="$1" state lock
  run_supervisor_env recover FAKE_OPKG_KEEP_REAL_VPN_UI=1 \
    > "$TMP_ROOT/rc5-bridge-$label.log" 2> "$TMP_ROOT/rc5-bridge-$label.err" || true
  state="$(jq -r .state "$RC5_JOURNAL")"
  [ "$state" = rolled_back ] || {
    printf 'RC5 target drift did not roll back safely: %s (%s)\n' "$label" "$state" >&2
    exit 1
  }
  [ ! -e "$FAKE_ROOT/etc/crontabs/root" ] && \
    [ ! -L "$FAKE_ROOT/etc/crontabs/root" ] || {
    printf 'RC5 target drift did not restore missing source cron: %s\n' "$label" >&2
    exit 1
  }
  lock="$FAKE_ROOT/root/premier-router-updates/update.lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || {
    printf 'RC5 target drift left the update lock behind: %s\n' "$label" >&2
    exit 1
  }
}

REAL_SORT_BIN="$(command -v sort)"
ORIGINAL_PATH="$PATH"
BUSYBOX_BIN_DIR="$TMP_ROOT/busybox-minimal-bin"
BUSYBOX_SORT_LOG="$TMP_ROOT/busybox-sort.log"
BUSYBOX_STAT_LOG="$TMP_ROOT/busybox-stat.log"
mkdir -p "$BUSYBOX_BIN_DIR"
cat > "$BUSYBOX_BIN_DIR/sort" <<'EOF'
#!/bin/sh
set -eu
if [ "${BUSYBOX_SORT_REJECT_OUTPUT:-0}" = 1 ]; then
  for argument in "$@"; do
    case "$argument" in
      -o|--output|--output=*)
        printf 'target BusyBox sort does not support %s\n' "$argument" >&2
        exit 64
        ;;
    esac
  done
fi
printf '%s\n' "$*" >> "$BUSYBOX_SORT_LOG"
exec "$REAL_SORT_BIN" "$@"
EOF
cat > "$BUSYBOX_BIN_DIR/stat" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BUSYBOX_STAT_LOG"
exit 127
EOF
chmod 755 "$BUSYBOX_BIN_DIR/sort" "$BUSYBOX_BIN_DIR/stat"
export REAL_SORT_BIN BUSYBOX_SORT_LOG BUSYBOX_SORT_REJECT_OUTPUT BUSYBOX_STAT_LOG
PATH="$BUSYBOX_BIN_DIR:$ORIGINAL_PATH"
export PATH
BUSYBOX_SORT_REJECT_OUTPUT=0
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
: > "$BUSYBOX_SORT_LOG"
: > "$BUSYBOX_STAT_LOG"
BUSYBOX_SORT_REJECT_OUTPUT=1
run_supervisor_env recover PATH="$PATH"
[ -s "$BUSYBOX_SORT_LOG" ]
[ -s "$BUSYBOX_STAT_LOG" ]
[ "$(jq -r .state "$RC5_JOURNAL")" = committed ]
[ -s "$RC5_ROLLBACK/protected-validation.paths.list" ]
[ -s "$RC5_ROLLBACK/protected-validation-source.fingerprint" ]
grep -Fqx '/etc/premier-router/xray-ownership.json' \
  "$RC5_ROLLBACK/protected-validation.paths.list"
grep -Fqx 'missing - - /etc/premier-router/xray-ownership.json' \
  "$RC5_ROLLBACK/protected-validation-source.fingerprint"
[ ! -e "$FAKE_ROOT/etc/premier-router/xray-ownership.json" ]
run_supervisor rollback "$RC5_TRANSACTION"
[ "$(jq -r .state "$RC5_JOURNAL")" = rolled_back ]
[ "$(sha256sum "$FAKE_ROOT/etc/crontabs/root" | awk '{ print $1 }')" = \
  "$RC5_SOURCE_CRON_SHA" ]
[ "$(sha256sum "$FAKE_ROOT/etc/init.d/xray-transparent" | awk '{ print $1 }')" = \
  "$RC5_SOURCE_TRANSPARENT_SHA" ]
[ "$(LC_ALL=C ls -ldn "$FAKE_ROOT/etc/init.d/xray-transparent" |
  awk '{ print $1 ":" $3 ":" $4 }')" = "$RC5_SOURCE_TRANSPARENT_METADATA" ]
PATH="$ORIGINAL_PATH"
export PATH
stage exact-rc5-reboot-metadata-bridge-busybox-sort

prepare_rc5_reboot_transaction missing
run_supervisor recover
[ "$(jq -r .state "$RC5_JOURNAL")" = committed ]
[ -f "$FAKE_ROOT/etc/crontabs/root" ] && [ ! -L "$FAKE_ROOT/etc/crontabs/root" ]
run_supervisor rollback "$RC5_TRANSACTION"
[ "$(jq -r .state "$RC5_JOURNAL")" = rolled_back ]
[ ! -e "$FAKE_ROOT/etc/crontabs/root" ] && [ ! -L "$FAKE_ROOT/etc/crontabs/root" ]
for package in premier-router-core luci-app-premier-router premier-router-setup; do
  postinst_path="$FAKE_ROOT/usr/lib/opkg/info/$package.postinst"
  [ -f "$postinst_path" ] && [ ! -L "$postinst_path" ] && [ -x "$postinst_path" ]
  tar -xzOf "$RC5_IPK_DIR/${package}_0.7.11~rc5-1_all.ipk" ./control.tar.gz |
    tar -xzOf - ./postinst | cmp -s - "$postinst_path"
done

# Continue from the actual rollback result without reseeding. Runtime opkg has
# retained all three RC5 postinst files; the second transaction must snapshot,
# authenticate, reboot-validate, and roll back that exact source shape.
prepare_rc5_reboot_transaction missing current-retained current
for package in premier-router-core luci-app-premier-router premier-router-setup; do
  grep -Fqx "/usr/lib/opkg/info/$package.postinst" "$RC5_ROLLBACK/protected.paths.list"
done
run_supervisor recover
[ "$(jq -r .state "$RC5_JOURNAL")" = committed ]
[ -s "$RC5_ROLLBACK/protected-validation.paths.list" ]
[ -s "$RC5_ROLLBACK/protected-validation-source.fingerprint" ]
run_supervisor rollback "$RC5_TRANSACTION"
[ "$(jq -r .state "$RC5_JOURNAL")" = rolled_back ]
[ ! -e "$FAKE_ROOT/etc/crontabs/root" ] && [ ! -L "$FAKE_ROOT/etc/crontabs/root" ]
stage exact-rc5-reboot-missing-cron-and-sequential-postinst-bridge

# A successful exact rollback on real OpenWrt can retain the three authenticated
# RC5 postinst control files even though the original bootstrap shape omitted
# them. The next RC5 -> RC15 reboot must accept that complete byte-bound shape,
# while partial or locally modified variants remain fail-closed.
prepare_rc5_reboot_transaction missing retained
for package in premier-router-core luci-app-premier-router premier-router-setup; do
  grep -Fqx "/usr/lib/opkg/info/$package.postinst" "$RC5_ROLLBACK/protected.paths.list"
done
run_supervisor recover
[ "$(jq -r .state "$RC5_JOURNAL")" = committed ]
[ -s "$RC5_ROLLBACK/protected-validation.paths.list" ]
[ -s "$RC5_ROLLBACK/protected-validation-source.fingerprint" ]
run_supervisor rollback "$RC5_TRANSACTION"
[ "$(jq -r .state "$RC5_JOURNAL")" = rolled_back ]
[ ! -e "$FAKE_ROOT/etc/crontabs/root" ] && [ ! -L "$FAKE_ROOT/etc/crontabs/root" ]
stage exact-rc5-reboot-post-rollback-postinst-bridge

prepare_rc5_reboot_transaction missing partial
expect_rc5_target_drift_rolled_back partial-retained-postinst

prepare_rc5_reboot_transaction missing tampered
expect_rc5_target_drift_rolled_back tampered-retained-postinst

prepare_rc5_reboot_transaction missing wrong-mode
expect_rc5_target_drift_rolled_back wrong-mode-retained-postinst

prepare_rc5_reboot_transaction missing symlink
expect_rc5_target_drift_rolled_back symlink-retained-postinst

stage rc5-reboot-retained-postinst-negative-cases

prepare_rc5_reboot_transaction missing
printf '%s\n' 'unauthorized operator cron drift' >> "$FAKE_ROOT/etc/crontabs/root"
expect_rc5_target_drift_rolled_back unexpected-cron-line

prepare_rc5_reboot_transaction missing
chmod 644 "$FAKE_ROOT/etc/crontabs/root"
expect_rc5_target_drift_rolled_back wrong-cron-mode

prepare_rc5_reboot_transaction missing
rm -f "$FAKE_ROOT/etc/crontabs/root"
ln -s /dev/null "$FAKE_ROOT/etc/crontabs/root"
expect_rc5_target_drift_rolled_back symlinked-cron
stage rc5-reboot-managed-cron-negative-cases

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
[ -s "$FAKE_ROOT/root/premier-router-updates/$transaction/rollback/protected-validation-transition" ]
grep -Fqx 'legacy-first-install:/etc/config/premier_router' \
  "$FAKE_ROOT/root/premier-router-updates/$transaction/rollback/protected-validation-transition"
[ ! -e "$FAKE_ROOT/etc/vpn-ui-update.conf-opkg" ]
[ ! -e "$FAKE_ROOT/etc/config/premier_router-opkg" ]
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
[ ! -e "$FAKE_ROOT/etc/config/premier_router" ]
[ ! -e "$FAKE_ROOT/etc/vpn-ui-update.conf-opkg" ]
stage adoption-aware-candidate-reboot-and-protected-rollback

reset_source 0.7.10
if run_update manual FAKE_OPKG_TAMPER_FIRST_INSTALL_METADATA=1; then
  printf 'tampered first-install metadata unexpectedly passed protected-state validation\n' >&2
  exit 1
fi
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = rolled_back ]
[ "$(jq -r .rollback_status "$journal")" = succeeded ]
[ ! -e "$FAKE_ROOT/etc/config/premier_router" ]
[ ! -e "$FAKE_ROOT/etc/vpn-ui-update.conf-opkg" ]
stage first-install-metadata-tamper-fails-closed

reset_source 0.7.10
if run_update manual FAKE_OPKG_ADD_UNAUTHORIZED_CONFIG=1; then
  printf 'unrelated protected-state addition unexpectedly passed validation\n' >&2
  exit 1
fi
transaction="$(cat "$FAKE_ROOT/root/premier-router-updates/active-transaction")"
journal="$FAKE_ROOT/root/premier-router-updates/$transaction/state.json"
[ "$(jq -r .state "$journal")" = rolled_back ]
[ "$(jq -r .rollback_status "$journal")" = succeeded ]
[ ! -e "$FAKE_ROOT/etc/config/not-authorized" ]
[ ! -e "$FAKE_ROOT/etc/config/premier_router" ]
stage unrelated-protected-addition-fails-closed

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
[ -s "$FAKE_ROOT/etc/config/premier_router" ]
[ "$(stat -c '%a' "$FAKE_ROOT/etc/config/premier_router" 2>/dev/null ||
  stat -f '%Lp' "$FAKE_ROOT/etc/config/premier_router")" = 600 ]
[ ! -e "$FAKE_ROOT/etc/vpn-ui-update.conf-opkg" ]
[ ! -e "$FAKE_ROOT/etc/config/premier_router-opkg" ]
grep -Fqx 'legacy-first-install:/etc/config/premier_router' \
  "$FAKE_ROOT/root/premier-router-updates/$transaction/rollback/protected-validation-transition"
grep -Fq ' /etc/config/premier_router' \
  "$FAKE_ROOT/root/premier-router-updates/$transaction/rollback/protected-validation-source.fingerprint"
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
[ ! -e "$FAKE_ROOT/etc/config/premier_router" ]
[ ! -e "$FAKE_ROOT/etc/vpn-ui-update.conf-opkg" ]
[ ! -e "$FAKE_ROOT/etc/config/premier_router-opkg" ]
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
