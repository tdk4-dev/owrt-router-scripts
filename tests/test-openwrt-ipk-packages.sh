#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CUSTOM_IMAGE_BUILDER="$ROOT_DIR/build-openwrt-custom-image-linux.sh"
X86_IMAGE_BUILDER="$ROOT_DIR/build-openwrt-x86-fin0-image-linux.sh"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$APP_VERSION-1"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/router-ipk-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

grep -Fq 'rm -f "$pkg_dir/${pkg}_"*.ipk' "$CUSTOM_IMAGE_BUILDER"
grep -Fq 'exec "$ROOT_DIR/build-openwrt-custom-image-linux.sh"' "$X86_IMAGE_BUILDER"
grep -Fq 'PROJECT_PACKAGE_MANIFEST="${PROJECT_PACKAGE_MANIFEST:-$PROJECT_PACKAGE_DIR/router-ui-packages.txt}"' "$CUSTOM_IMAGE_BUILDER"
grep -Fq 'cp "$PROJECT_PACKAGE_MANIFEST"' "$CUSTOM_IMAGE_BUILDER"

build_ipks() {
  SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567 \
  SOURCE_DIRTY=false \
  SOURCE_DATE_EPOCH=1700000000 \
  BUILD_DIR="$TMP_DIR/build" \
  OUT_DIR="$TMP_DIR/ipk" \
  FEED_DIR="$TMP_DIR/feed" \
    "$ROOT_DIR/scripts/build-openwrt-ipks.sh" >"$TMP_DIR/build.log"
}

build_ipks
first_build_hashes="$(sha256sum "$TMP_DIR"/ipk/*.ipk)"
build_ipks
second_build_hashes="$(sha256sum "$TMP_DIR"/ipk/*.ipk)"
[ "$first_build_hashes" = "$second_build_hashes" ] || {
  printf 'repeated clean IPK builds produced different checksums\n' >&2
  exit 1
}

for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  ipk="$TMP_DIR/ipk/${pkg}_${PKG_VERSION}_all.ipk"
  [ -f "$ipk" ] || {
    printf 'missing package: %s\n' "$ipk" >&2
    exit 1
  }
  file "$ipk" | grep -qi 'gzip compressed data'
  tar -tzf "$ipk" | grep -qx './debian-binary'
  tar -tzf "$ipk" | grep -qx './control.tar.gz'
  tar -tzf "$ipk" | grep -qx './data.tar.gz'
  if gzip -dc "$ipk" | grep -aEq 'PaxHeader|SCHILY\.xattr|LIBARCHIVE\.xattr|com\.apple'; then
    printf 'package outer archive contains unsupported PAX/macOS metadata: %s\n' "$ipk" >&2
    exit 1
  fi
  if tar -xzOf "$ipk" ./control.tar.gz | gzip -dc | grep -aEq 'PaxHeader|SCHILY\.xattr|LIBARCHIVE\.xattr|com\.apple'; then
    printf 'package control archive contains unsupported PAX/macOS metadata: %s\n' "$ipk" >&2
    exit 1
  fi
  if tar -xzOf "$ipk" ./data.tar.gz | gzip -dc | grep -aEq 'PaxHeader|SCHILY\.xattr|LIBARCHIVE\.xattr|com\.apple'; then
    printf 'package data archive contains unsupported PAX/macOS metadata: %s\n' "$ipk" >&2
    exit 1
  fi
  mkdir -p "$TMP_DIR/$pkg/control" "$TMP_DIR/$pkg/data"
  tar -xzOf "$ipk" ./control.tar.gz | tar -xzf - -C "$TMP_DIR/$pkg/control"
  tar -xzOf "$ipk" ./data.tar.gz | tar -xzf - -C "$TMP_DIR/$pkg/data"
  grep -qx "Package: $pkg" "$TMP_DIR/$pkg/control/control"
  grep -qx "Version: $PKG_VERSION" "$TMP_DIR/$pkg/control/control"
  grep -qx "Architecture: all" "$TMP_DIR/$pkg/control/control"
  grep -q '^Depends: ' "$TMP_DIR/$pkg/control/control"
  if [ "$pkg" = "premier-router-core" ]; then
    grep -qx '/etc/config/premier_router' "$TMP_DIR/$pkg/control/conffiles"
    grep -qx '/etc/vpn-ui-update.conf' "$TMP_DIR/$pkg/control/conffiles"
    grep -q 'vpn-ui metadata-init' "$TMP_DIR/$pkg/control/postinst"
    grep -q 'vpn-ui metadata-installed package-first-local-ipk' "$TMP_DIR/$pkg/control/postinst"
    grep -q 'rm -rf /tmp/vpn-ui-pings' "$TMP_DIR/$pkg/control/postinst"
  fi
done

[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui-update" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/install-router-ui-release" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/libexec/premier-router/update-lib.sh" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/libexec/premier-router/candidate-validator" ]
[ -x "$TMP_DIR/premier-router-core/data/etc/init.d/premier-router-update-recovery" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/version" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/build-info" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/premier-router/build-info" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/legacy-files.list" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/premier-router/keys/release.pub" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/premier-router/keys/release-key-id" ]
[ -f "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf" ]
[ -f "$TMP_DIR/premier-router-core/data/etc/config/premier_router" ]
grep -q 'metadata|router-metadata|footer-info' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q 'metadata-set)' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q 'metadata-installed)' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q 'installed-build)' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q '^PACKAGE_VERSION=0.8.0RC2-1$' "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/build-info"
grep -q "option install_method 'manual-ipk-install'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
grep -q "option support_level 'self-managed'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
grep -q "option registration_state 'local-only'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
grep -q "option direct_rules_channel 'stable'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
grep -q 'support_access_state' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q '^UPDATER_PROTOCOL=2$' "$TMP_DIR/premier-router-core/data/usr/share/premier-router/build-info"
grep -q '^SOURCE_DIRTY=false$' "$TMP_DIR/premier-router-core/data/usr/share/premier-router/build-info"
grep -q '^UPDATER_PROTOCOL=2$' "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/build-info"
if command -v stat >/dev/null 2>&1; then
  mode="$(stat -c '%a' "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf" 2>/dev/null ||
    stat -f '%Lp' "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf")"
  [ "$mode" = "600" ]
  metadata_mode="$(stat -c '%a' "$TMP_DIR/premier-router-core/data/etc/config/premier_router" 2>/dev/null ||
    stat -f '%Lp' "$TMP_DIR/premier-router-core/data/etc/config/premier_router")"
  [ "$metadata_mode" = "600" ]
fi

[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/vpn.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/vpn-0-7-0.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/tailscale-0-7-5.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/tools/router_footer.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/system/reset.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/system/reset-0-8-0.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/system/update-0-7-3.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/status/include/35_vpn.js" ]
[ "$(find "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/status/include" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ]
[ ! -e "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js" ]
[ ! -e "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/status/include/_35_vpn.js" ]
[ ! -e "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js" ]
grep -q '/status/include/_35_vpn.js' "$TMP_DIR/luci-app-premier-router/control/postinst"
[ ! -e "$TMP_DIR/luci-app-premier-router/data/usr/share/ucode/luci/template/themes/bootstrap/footer.ut" ]
[ ! -e "$TMP_DIR/luci-app-premier-router/data/usr/share/ucode/luci/template/themes/bootstrap-dark/footer.ut" ]
[ ! -e "$TMP_DIR/luci-app-premier-router/data/usr/share/ucode/luci/template/themes/bootstrap-light/footer.ut" ]
grep -q "\['footer-info'\]" "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/status/include/35_vpn.js"
grep -q 'Support access' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/tools/router_footer.js"
grep -q 'router_metadata' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/vpn.js"
grep -q 'adguard-status' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js"
grep -q 'adguard-install' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js"
grep -q 'Persistent storage' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js"
grep -q 'optional network-wide DNS filtering service' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js"
grep -q 'Open AdGuardHome web panel' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js"
grep -q "'http://' + window.location.hostname + ':3000/'" "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/adguard.js"
grep -q 'admin/network/adguardhome' "$TMP_DIR/luci-app-premier-router/data/usr/share/luci/menu.d/luci-app-vpn-ui.json"
for view in \
  network/vpn.js \
  network/tailscale.js \
  system/update.js \
  system/reset.js
do
  grep -q 'require tools.router_footer as routerFooter' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/$view"
  ! grep -q 'router-panel-footer' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/$view"
done
[ -f "$TMP_DIR/luci-app-premier-router/data/usr/share/luci/menu.d/luci-app-vpn-ui.json" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" ]

[ -x "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup" ]
grep -q 'adguard_available' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q '"adguardEnabled":false' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q 'existing service and DNS state were left unchanged' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q '^ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-openwrt-fin0}"' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
! grep -q '^HOSTNAME=' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q 'AdGuardHome is not installed' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'data-action="install-adguard"' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'Writable flash / disk storage' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q "LuCI's Memory total is router RAM" "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q "path: 'router.hostname'" "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
! grep -q "path: 'account.login'" "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'Administrator account' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'grid-template-columns: repeat(6' "$TMP_DIR/premier-router-setup/data/www/setup/styles.css"
grep -q 'grid-template-columns: minmax(0, 1fr)' "$TMP_DIR/premier-router-setup/data/www/setup/styles.css"
grep -q 'background: transparent' "$TMP_DIR/premier-router-setup/data/www/setup/styles.css"
grep -q 'adguard-install) install_adguard' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q 'adguard_allowed_for_hardware' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q "steps.splice(adguardStep, 1)" "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'verify_tailscale_registration' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q 'name="adguard-enabled"' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'adguardEnabled' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
[ -x "$TMP_DIR/premier-router-setup/data/www/cgi-bin/router-prep" ]
[ -x "$TMP_DIR/premier-router-setup/data/usr/sbin/router-prep" ]
[ ! -f "$TMP_DIR/premier-router-setup/data/www/index.html" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/premier-router-index.html" ]
grep -q "premier-router-index.html" "$TMP_DIR/premier-router-setup/control/postinst"
[ -f "$TMP_DIR/premier-router-setup/data/www/setup/app.js" ]
grep -q 'styles.css?v=0.8.0RC2-rc-polish-5' "$TMP_DIR/premier-router-setup/data/www/setup/index.html"
grep -q 'app.js?v=0.8.0RC2-rc-polish-5' "$TMP_DIR/premier-router-setup/data/www/setup/index.html"
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/index.html" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/app.js" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/styles.css" ]
grep -q 'rm -f /etc/uci-defaults/99-openwrt-fin0-firstboot' "$TMP_DIR/premier-router-setup/control/postinst"
grep -q 'metadata-set self-managed-image self-managed local-only' "$TMP_DIR/premier-router-setup/data/etc/uci-defaults/99-openwrt-fin0-firstboot"
grep -Fq 'uci -q delete firewall.lan_wan_forward || true' "$TMP_DIR/premier-router-setup/data/etc/uci-defaults/99-openwrt-fin0-firstboot"
grep -q 'SUPPORT_LEVEL' "$TMP_DIR/premier-router-setup/data/usr/sbin/router-prep"
grep -q 'REGISTRATION_STATE' "$TMP_DIR/premier-router-setup/data/usr/sbin/router-prep"

for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  (
    cd "$TMP_DIR/$pkg/data"
    if find . -type f | grep -E '(^|/)(tmp|root)/|\.tar\.gz$|\.img(\.gz)?$|\.pcap$|\.env$'; then
      printf '%s package contains local/generated artifacts\n' "$pkg" >&2
      exit 1
    fi
    if find . -type f | grep -Ei '(id_rsa|known_hosts|authorized_keys|backup|cache|log|pcap|secret|token|private.?key)'; then
      printf '%s package contains secret-shaped or generated paths\n' "$pkg" >&2
      exit 1
    fi
  )
done

printf 'OpenWrt IPK package validation passed\n'
