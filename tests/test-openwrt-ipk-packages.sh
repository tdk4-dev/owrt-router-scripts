#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_VERSION="$APP_VERSION-1"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/router-ipk-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

"$ROOT_DIR/scripts/build-openwrt-ipks.sh" >/tmp/router-ipk-build-test.log

for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  ipk="$ROOT_DIR/dist/ipk/${pkg}_${PKG_VERSION}_all.ipk"
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
  fi
done

[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui-update" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/install-router-ui-release" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/version" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/legacy-files.list" ]
[ -f "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf" ]
[ -f "$TMP_DIR/premier-router-core/data/etc/config/premier_router" ]
grep -q 'metadata|router-metadata|footer-info' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q 'metadata-set)' "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui"
grep -q "option install_method 'manual-ipk-install'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
grep -q "option support_level 'self-managed'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
grep -q "option registration_state 'local-only'" "$TMP_DIR/premier-router-core/data/etc/config/premier_router"
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
grep -q 'router_metadata' "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/vpn.js"
[ -f "$TMP_DIR/luci-app-premier-router/data/usr/share/luci/menu.d/luci-app-vpn-ui.json" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" ]

[ -x "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup" ]
grep -q 'adguard_available' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q '"adguardEnabled":false' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q 'existing service and DNS state were left unchanged' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q '^ROUTER_HOSTNAME="${ROUTER_HOSTNAME:-openwrt-fin0}"' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
! grep -q '^HOSTNAME=' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
grep -q 'AdGuardHome is not installed' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'name="adguard-enabled"' "$TMP_DIR/premier-router-setup/data/www/setup/app.js"
grep -q 'adguardEnabled' "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup"
[ -x "$TMP_DIR/premier-router-setup/data/www/cgi-bin/router-prep" ]
[ -x "$TMP_DIR/premier-router-setup/data/usr/sbin/router-prep" ]
[ ! -f "$TMP_DIR/premier-router-setup/data/www/index.html" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/setup/app.js" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/index.html" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/app.js" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/styles.css" ]
grep -q 'rm -f /etc/uci-defaults/99-openwrt-fin0-firstboot' "$TMP_DIR/premier-router-setup/control/postinst"
grep -q 'metadata-set self-managed-image self-managed local-only' "$TMP_DIR/premier-router-setup/data/etc/uci-defaults/99-openwrt-fin0-firstboot"
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
