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
  if file "$ipk" | grep -qi 'gzip compressed data'; then
    printf 'package is a gzip/tar wrapper, not an ar-format OpenWrt IPK: %s\n' "$ipk" >&2
    file "$ipk" >&2
    exit 1
  fi
  ar -t "$ipk" | grep -qx 'debian-binary'
  ar -t "$ipk" | grep -qx 'control.tar.gz'
  ar -t "$ipk" | grep -qx 'data.tar.gz'
  mkdir -p "$TMP_DIR/$pkg/control" "$TMP_DIR/$pkg/data"
  (
    cd "$TMP_DIR/$pkg"
    ar -x "$ipk" control.tar.gz data.tar.gz
    tar -xzf control.tar.gz -C control
    tar -xzf data.tar.gz -C data
  )
  grep -qx "Package: $pkg" "$TMP_DIR/$pkg/control/control"
  grep -qx "Version: $PKG_VERSION" "$TMP_DIR/$pkg/control/control"
  grep -qx "Architecture: all" "$TMP_DIR/$pkg/control/control"
  grep -q '^Depends: ' "$TMP_DIR/$pkg/control/control"
  if [ "$pkg" = "premier-router-core" ]; then
    grep -qx '/etc/vpn-ui-update.conf' "$TMP_DIR/$pkg/control/conffiles"
  fi
  find "$TMP_DIR/$pkg/data" -type f |
    grep -Ev '/(\.DS_Store|id_rsa|known_hosts|authorized_keys|\.env|backup|cache|log|pcap|secret|token)' >/dev/null || true
done

[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/vpn-ui-update" ]
[ -x "$TMP_DIR/premier-router-core/data/usr/sbin/install-router-ui-release" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/version" ]
[ -f "$TMP_DIR/premier-router-core/data/usr/share/vpn-ui/legacy-files.list" ]
[ -f "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf" ]
if command -v stat >/dev/null 2>&1; then
  mode="$(stat -c '%a' "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf" 2>/dev/null ||
    stat -f '%Lp' "$TMP_DIR/premier-router-core/data/etc/vpn-ui-update.conf")"
  [ "$mode" = "600" ]
fi

[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/network/vpn.js" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/www/luci-static/resources/view/system/reset.js" ]
[ ! -e "$TMP_DIR/luci-app-premier-router/data/usr/share/ucode/luci/template/themes/bootstrap-dark/footer.ut" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/usr/share/luci/menu.d/luci-app-vpn-ui.json" ]
[ -f "$TMP_DIR/luci-app-premier-router/data/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" ]

[ -x "$TMP_DIR/premier-router-setup/data/www/cgi-bin/firstboot-setup" ]
[ -x "$TMP_DIR/premier-router-setup/data/www/cgi-bin/router-prep" ]
[ -x "$TMP_DIR/premier-router-setup/data/usr/sbin/router-prep" ]
[ ! -f "$TMP_DIR/premier-router-setup/data/www/index.html" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/setup/app.js" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/index.html" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/app.js" ]
[ -f "$TMP_DIR/premier-router-setup/data/www/prepare/styles.css" ]
grep -q 'rm -f /etc/uci-defaults/99-openwrt-fin0-firstboot' "$TMP_DIR/premier-router-setup/control/postinst"

for pkg in premier-router-core luci-app-premier-router premier-router-setup; do
  (
    cd "$TMP_DIR/$pkg/data"
    if find . -type f | grep -E '(^|/)(tmp|root)/|\.tar\.gz$|\.img(\.gz)?$|\.pcap$|\.env$'; then
      printf '%s package contains local/generated artifacts\n' "$pkg" >&2
      exit 1
    fi
  )
done

printf 'OpenWrt IPK package validation passed\n'
