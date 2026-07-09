#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP_VERSION="$(sed -n '1p' "$ROOT_DIR/luci-vpn-ui/VERSION" | tr -d '\r\n')"
PKG_RELEASE="${PKG_RELEASE:-1}"
PKG_VERSION="$APP_VERSION-$PKG_RELEASE"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.package-build}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist/ipk}"
FEED_DIR="${FEED_DIR:-$ROOT_DIR/dist/opkg-feed}"
SOURCE_COMMIT="${SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for tool in awk find gzip sed sha256sum sort tar; do
  need "$tool"
done

[ -n "$APP_VERSION" ] || {
  printf 'luci-vpn-ui/VERSION is empty\n' >&2
  exit 1
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR" "$FEED_DIR"

copy_file() {
  src="$1"
  dst="$2"
  mode="$3"
  [ -f "$src" ] || {
    printf 'Missing package source file: %s\n' "$src" >&2
    exit 1
  }
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  chmod "$mode" "$dst"
}

copy_tree_file_modes() {
  src="$1"
  dst="$2"
  [ -d "$src" ] || {
    printf 'Missing package source directory: %s\n' "$src" >&2
    exit 1
  }
  mkdir -p "$dst"
  cp -R "$src/." "$dst/"
  find "$dst" -type d -exec chmod 755 {} \;
  find "$dst" -type f -exec chmod 644 {} \;
}

write_control() {
  pkg="$1"
  depends="$2"
  description="$3"
  control_dir="$4"
  mkdir -p "$control_dir"
  cat > "$control_dir/control" <<EOF
Package: $pkg
Version: $PKG_VERSION
Depends: $depends
Source: $SOURCE_COMMIT
Architecture: all
Maintainer: Premier Router Maintainers <support@example.invalid>
Section: net
Priority: optional
Description: $description
EOF
}

write_core_scripts() {
  control_dir="$1"
  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

chmod 755 /usr/sbin/vpn-ui /usr/sbin/vpn-ui-update 2>/dev/null || true

if [ -x /usr/sbin/vpn-ui ]; then
  /usr/sbin/vpn-ui metadata-init >/tmp/premier-router-metadata-init.log 2>&1 || true
  /usr/sbin/vpn-ui init >/tmp/premier-router-core-init.log 2>&1 || true
fi

mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i '\|/usr/sbin/vpn-ui auto-tick|d' /etc/crontabs/root 2>/dev/null || true
printf '%s\n' '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' >> /etc/crontabs/root

if [ -x /usr/sbin/vpn-ui-update ]; then
  /usr/sbin/vpn-ui-update configure-cron >/tmp/premier-router-update-cron.log 2>&1 || true
fi

/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true
exit 0
EOF
  cat > "$control_dir/postrm" <<'EOF'
#!/bin/sh
set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

if [ -f /etc/crontabs/root ]; then
  sed -i '\|/usr/sbin/vpn-ui auto-tick|d;\|/usr/sbin/vpn-ui-update auto|d' /etc/crontabs/root 2>/dev/null || true
  /etc/init.d/cron restart >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 755 "$control_dir/postinst" "$control_dir/postrm"
cat > "$control_dir/conffiles" <<'EOF'
/etc/config/premier_router
/etc/vpn-ui-update.conf
EOF
}

write_luci_scripts() {
  control_dir="$1"
  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
exit 0
EOF
  cat > "$control_dir/postrm" <<'EOF'
#!/bin/sh
set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
exit 0
EOF
  chmod 755 "$control_dir/postinst" "$control_dir/postrm"
}

write_setup_scripts() {
  control_dir="$1"
  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

chmod 755 /www/cgi-bin/firstboot-setup /www/cgi-bin/router-prep /usr/sbin/router-prep 2>/dev/null || true
chmod 755 /etc/uci-defaults/99-openwrt-fin0-firstboot 2>/dev/null || true
if [ "${PREMIER_ROUTER_KEEP_UCI_DEFAULTS:-0}" != "1" ]; then
  rm -f /etc/uci-defaults/99-openwrt-fin0-firstboot
fi
rm -f /tmp/luci-indexcache.*.json 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
exit 0
EOF
  cat > "$control_dir/postrm" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$control_dir/postinst" "$control_dir/postrm"
}

write_legacy_manifest() {
  dst="$1"
  mkdir -p "$(dirname "$dst")"
  cat > "$dst" <<'EOF'
/www/luci-static/resources/view/network/vpn-0-6-0.js
/www/luci-static/resources/view/network/tailscale-0-6-0.js
/www/luci-static/resources/view/network/tailscale-0-7-0.js
/www/luci-static/resources/view/network/tailscale-0-7-4.js
/www/luci-static/resources/view/network/vpn-0-5-2.js
/www/luci-static/resources/view/network/tailscale-0-5-2.js
/www/luci-static/resources/view/system/update-0-6-0.js
/www/luci-static/resources/view/system/update-0-7-0.js
/www/luci-static/resources/view/system/update-0-7-1.js
/www/luci-static/resources/view/system/update-0-7-2.js
EOF
  chmod 644 "$dst"
}

create_package() {
  pkg="$1"
  root="$BUILD_DIR/$pkg/root"
  control="$BUILD_DIR/$pkg/control"
  work="$BUILD_DIR/$pkg/archive"
  ipk="$OUT_DIR/${pkg}_${PKG_VERSION}_all.ipk"

  mkdir -p "$work"
  find "$root" -type d -exec chmod 755 {} \;
  find "$control" -type d -exec chmod 755 {} \;
  printf '2.0\n' > "$work/debian-binary"
  create_tar_gz "$control" "$work/control.tar.gz"
  create_tar_gz "$root" "$work/data.tar.gz"
  rm -f "$ipk"
  create_tar_gz "$work" "$ipk" ./debian-binary ./control.tar.gz ./data.tar.gz
  cp "$ipk" "$FEED_DIR/"
  printf '%s\n' "$ipk"
}

create_tar_gz() {
  src_dir="$1"
  dst="$2"
  shift 2
  if [ "$#" -eq 0 ]; then
    set -- .
  fi
  (
    cd "$src_dir"
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
      tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner -cf - "$@" | gzip -n > "$dst"
    else
      COPYFILE_DISABLE=1 tar --format ustar --no-xattrs --no-mac-metadata \
        --owner=0 --group=0 --numeric-owner -czf "$dst" "$@"
    fi
  )
}

CORE_ROOT="$BUILD_DIR/premier-router-core/root"
CORE_CONTROL="$BUILD_DIR/premier-router-core/control"
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui" "$CORE_ROOT/usr/sbin/vpn-ui" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" "$CORE_ROOT/usr/sbin/vpn-ui-update" 755
copy_file "$ROOT_DIR/install-router-ui-release.sh" "$CORE_ROOT/usr/sbin/install-router-ui-release" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/share/vpn-ui/version" "$CORE_ROOT/usr/share/vpn-ui/version" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/etc/config/premier_router" "$CORE_ROOT/etc/config/premier_router" 600
mkdir -p "$CORE_ROOT/etc"
cat > "$CORE_ROOT/etc/vpn-ui-update.conf" <<'EOF'
AUTO_UPDATE='0'
AUTO_SCHEDULE='Sunday 04:17'
EOF
chmod 600 "$CORE_ROOT/etc/vpn-ui-update.conf"
write_legacy_manifest "$CORE_ROOT/usr/share/vpn-ui/legacy-files.list"
write_control \
  "premier-router-core" \
  "curl, jsonfilter, nftables-json, coreutils-base64, socat, tailscale, xray-core" \
  "Premier Router backend scripts, VPN generation, update checks, health checks, and reset control." \
  "$CORE_CONTROL"
write_core_scripts "$CORE_CONTROL"

LUCI_ROOT="$BUILD_DIR/luci-app-premier-router/root"
LUCI_CONTROL="$BUILD_DIR/luci-app-premier-router/control"
copy_tree_file_modes "$ROOT_DIR/luci-vpn-ui/files/www" "$LUCI_ROOT/www"
# Transitional aliases are generated into the package from the stable source
# assets. Older installed updaters validate these names during the handoff to
# package-first v0.8, while source development continues to use stable names.
copy_file "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js" "$LUCI_ROOT/www/luci-static/resources/view/network/vpn-0-7-0.js" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js" "$LUCI_ROOT/www/luci-static/resources/view/network/tailscale-0-7-5.js" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/update.js" "$LUCI_ROOT/www/luci-static/resources/view/system/update-0-7-3.js" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/system/reset.js" "$LUCI_ROOT/www/luci-static/resources/view/system/reset-0-8-0.js" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/status/include/35_vpn.js" "$LUCI_ROOT/www/luci-static/resources/view/status/include/35_vpn-0-7-0.js" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/www/luci-static/resources/view/status/include/_35_vpn.js" "$LUCI_ROOT/www/luci-static/resources/view/status/include/_35_vpn-0-7-0.js" 644
# LuCI theme footer templates are deliberately not package-owned. Router
# metadata is shown through package-owned Status Overview and Router UI assets
# until a supported footer hook is runtime-validated.
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/share/luci/menu.d/luci-app-vpn-ui.json" "$LUCI_ROOT/usr/share/luci/menu.d/luci-app-vpn-ui.json" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" "$LUCI_ROOT/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" 644
write_control \
  "luci-app-premier-router" \
  "luci-base, rpcd, rpcd-mod-file, premier-router-core (= $PKG_VERSION)" \
  "Premier Router LuCI pages, RPC ACLs, menu entries, and UI assets." \
  "$LUCI_CONTROL"
write_luci_scripts "$LUCI_CONTROL"

SETUP_ROOT="$BUILD_DIR/premier-router-setup/root"
SETUP_CONTROL="$BUILD_DIR/premier-router-setup/control"
copy_tree_file_modes "$ROOT_DIR/image-overlay" "$SETUP_ROOT"
# /www/index.html is owned by luci-base on OpenWrt images. Keep the root
# setup redirect as an image-only overlay to avoid opkg file clashes.
rm -f "$SETUP_ROOT/www/index.html"
mkdir -p "$SETUP_ROOT/www/setup"
copy_file "$ROOT_DIR/firstboot-wizard/www/index.html" "$SETUP_ROOT/www/setup/index.html" 644
copy_file "$ROOT_DIR/firstboot-wizard/www/styles.css" "$SETUP_ROOT/www/setup/styles.css" 644
copy_file "$ROOT_DIR/firstboot-wizard/www/app.js" "$SETUP_ROOT/www/setup/app.js" 644
for executable in \
  "$SETUP_ROOT/etc/uci-defaults/99-openwrt-fin0-firstboot" \
  "$SETUP_ROOT/www/cgi-bin/firstboot-setup" \
  "$SETUP_ROOT/www/cgi-bin/router-prep" \
  "$SETUP_ROOT/usr/sbin/router-prep"
do
  [ -f "$executable" ] && chmod 755 "$executable"
done
write_control \
  "premier-router-setup" \
  "cgi-io, iwinfo, uhttpd, premier-router-core (= $PKG_VERSION)" \
  "Premier Router first-boot setup assistant, preparation UI, reset target, and image defaults." \
  "$SETUP_CONTROL"
write_setup_scripts "$SETUP_CONTROL"

rm -f "$OUT_DIR"/*.ipk "$FEED_DIR"/*.ipk "$FEED_DIR"/Packages "$FEED_DIR"/Packages.gz "$FEED_DIR"/SHA256SUMS
CORE_IPK="$(create_package premier-router-core)"
LUCI_IPK="$(create_package luci-app-premier-router)"
SETUP_IPK="$(create_package premier-router-setup)"

(
  cd "$FEED_DIR"
  for file in *.ipk; do
    [ -f "$file" ] || continue
    control_tmp="$BUILD_DIR/feed-control"
    rm -rf "$control_tmp"
    mkdir -p "$control_tmp"
    tar -xzOf "$file" ./control.tar.gz | tar -xzf - -C "$control_tmp"
    size="$(wc -c < "$file" | tr -d ' ')"
    sha="$(sha256sum "$file" | awk '{ print $1 }')"
    cat "$control_tmp/control"
    printf 'Filename: %s\n' "$file"
    printf 'Size: %s\n' "$size"
    printf 'SHA256sum: %s\n\n' "$sha"
  done > Packages
  gzip -kf Packages
  sha256sum *.ipk Packages Packages.gz > SHA256SUMS
)

PACKAGES_TXT="$OUT_DIR/router-ui-packages.txt"
{
  for ipk in "$CORE_IPK" "$LUCI_IPK" "$SETUP_IPK"; do
    file="$(basename "$ipk")"
    pkg="${file%%_*}"
    sha="$(sha256sum "$ipk" | awk '{ print $1 }')"
    size="$(wc -c < "$ipk" | tr -d ' ')"
    printf '%s %s all %s %s %s\n' "$pkg" "$PKG_VERSION" "$sha" "$size" "$file"
  done
} > "$PACKAGES_TXT"

printf 'Built OpenWrt IPKs in %s\n' "$OUT_DIR"
printf 'Generated local opkg feed in %s\n' "$FEED_DIR"
