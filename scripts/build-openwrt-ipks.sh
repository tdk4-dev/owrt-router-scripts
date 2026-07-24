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
SOURCE_DIRTY="${SOURCE_DIRTY:-}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct "$SOURCE_COMMIT" 2>/dev/null || printf 0)}"
UPDATER_PROTOCOL=2
USIGN_BIN="${USIGN_BIN:-usign}"
STRICT_RELEASE="${STRICT_RELEASE:-0}"
ROUTER_UI_RELEASE_ROOT="$ROOT_DIR"
export ROUTER_UI_RELEASE_ROOT
. "$ROOT_DIR/scripts/release-key-lib.sh"

if [ -z "$SOURCE_DIRTY" ]; then
  if [ -n "$(git -C "$ROOT_DIR" status --short 2>/dev/null)" ]; then
    SOURCE_DIRTY=true
  else
    SOURCE_DIRTY=false
  fi
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

for tool in awk env find gzip jq sed sha256sum sort tar "$USIGN_BIN"; do
  need "$tool"
done

pr_select_active_public_key || exit 1

[ -n "$APP_VERSION" ] || {
  printf 'luci-vpn-ui/VERSION is empty\n' >&2
  exit 1
}
[ "$APP_VERSION" = "0.7.11" ] || {
  printf '0.7.11 bridge package build refuses app version %s\n' "$APP_VERSION" >&2
  exit 1
}
case "$SOURCE_DIRTY" in true|false) ;; *)
  printf 'SOURCE_DIRTY must be true or false\n' >&2
  exit 1
esac
[ -s "$RELEASE_PUBLIC_KEY" ] || {
  printf 'Release verification public key is missing: %s\n' "$RELEASE_PUBLIC_KEY" >&2
  exit 1
}
printf '%s' "$RELEASE_KEY_ID" | grep -Eq '^[A-Za-z0-9._-]+$' || {
  printf 'RELEASE_KEY_ID is malformed\n' >&2
  exit 1
}
if [ "$STRICT_RELEASE" = 1 ]; then
  pr_require_committed_registry || exit 1
fi

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

render_trust_script() {
  src="$1"
  dst="$2"
  key_comment="$(sed -n '1p' "$RELEASE_PUBLIC_KEY" | tr -d '\r\n')"
  key_data="$(sed -n '2p' "$RELEASE_PUBLIC_KEY" | tr -d '\r\n')"
  printf '%s' "$key_comment" | grep -Eq '^untrusted comment: [A-Za-z0-9 ._:/+-]+$' || {
    printf 'Release public key comment is not safe to embed\n' >&2
    exit 1
  }
  printf '%s' "$key_data" | grep -Eq '^RW[A-Za-z0-9+/=]+$' || {
    printf 'Release public key data is malformed\n' >&2
    exit 1
  }
  awk -v key_id="$RELEASE_KEY_ID" -v fingerprint="$RELEASE_KEY_FINGERPRINT" \
    -v key_comment="$key_comment" -v key_data="$key_data" '
    /^TRUSTED_KEY_ID=/ { print "TRUSTED_KEY_ID=\047" key_id "\047"; next }
    /^TRUSTED_KEY_FINGERPRINT=/ { print "TRUSTED_KEY_FINGERPRINT=\047" fingerprint "\047"; next }
    /^TRUSTED_KEY_COMMENT=/ { print "TRUSTED_KEY_COMMENT=\047" key_comment "\047"; next }
    /^TRUSTED_KEY_DATA=/ { print "TRUSTED_KEY_DATA=\047" key_data "\047"; next }
    { print }
  ' "$src" > "$dst"
  chmod 755 "$dst"
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

mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i '\|/usr/sbin/vpn-ui auto-tick|d' /etc/crontabs/root 2>/dev/null || true
printf '%s\n' '*/1 * * * * /usr/sbin/vpn-ui auto-tick >/tmp/vpn-ui-auto.log 2>&1' >> /etc/crontabs/root
/usr/sbin/vpn-ui-update configure-cron
/etc/init.d/premier-router-update-recovery enable
exit 0
EOF
  cat > "$control_dir/postrm" <<'EOF'
#!/bin/sh
set -eu

[ -n "${IPKG_INSTROOT:-}" ] && exit 0

if [ -f /etc/crontabs/root ]; then
  sed -i '\|/usr/sbin/vpn-ui auto-tick|d;\|/usr/sbin/vpn-ui-update auto|d' /etc/crontabs/root 2>/dev/null || true
fi
exit 0
EOF
  chmod 755 "$control_dir/postinst" "$control_dir/postrm"
cat > "$control_dir/conffiles" <<'EOF'
/etc/vpn-ui-update.conf
EOF
}

write_luci_scripts() {
  control_dir="$1"
  cat > "$control_dir/postinst" <<'EOF'
#!/bin/sh
set -eu
exit 0
EOF
  cat > "$control_dir/postrm" <<'EOF'
#!/bin/sh
set -eu
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
chmod 755 /etc/uci-defaults/99-openwrt-fin0-firstboot 2>/dev/null || true
if [ "${PREMIER_ROUTER_KEEP_UCI_DEFAULTS:-0}" != "1" ]; then
  rm -f /etc/uci-defaults/99-openwrt-fin0-firstboot
fi
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
      normalized_mtime="$(date -u -r "$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S')"
      find . -exec env TZ=UTC touch -h -t "$normalized_mtime" {} +
      COPYFILE_DISABLE=1 tar --format ustar --no-xattrs --no-mac-metadata \
        --owner=0 --group=0 --numeric-owner -cf - "$@" | gzip -n > "$dst"
    fi
  )
}

CORE_ROOT="$BUILD_DIR/premier-router-core/root"
CORE_CONTROL="$BUILD_DIR/premier-router-core/control"
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui" "$CORE_ROOT/usr/sbin/vpn-ui" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-readonly" "$CORE_ROOT/usr/sbin/vpn-ui-readonly" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui-update" "$CORE_ROOT/usr/sbin/vpn-ui-update" 755
mkdir -p "$CORE_ROOT/usr/sbin"
render_trust_script "$ROOT_DIR/install-router-ui-release.sh" \
  "$CORE_ROOT/usr/sbin/install-router-ui-release"
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh" \
  "$CORE_ROOT/usr/libexec/premier-router/update-lib.sh" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator" \
  "$CORE_ROOT/usr/libexec/premier-router/candidate-validator" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/etc/init.d/premier-router-update-recovery" \
  "$CORE_ROOT/etc/init.d/premier-router-update-recovery" 755
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/share/vpn-ui/version" "$CORE_ROOT/usr/share/vpn-ui/version" 644
copy_file "$RELEASE_PUBLIC_KEY" "$CORE_ROOT/usr/share/premier-router/keys/release.pub" 644
mkdir -p "$CORE_ROOT/usr/share/premier-router/keys"
printf '%s\n' "$RELEASE_KEY_ID" > "$CORE_ROOT/usr/share/premier-router/keys/release-key-id"
chmod 644 "$CORE_ROOT/usr/share/premier-router/keys/release-key-id"
mkdir -p "$CORE_ROOT/usr/share/premier-router/keys/release"
jq '.keys |= map(.public_key_path = (.public_key_path | split("/") | last))' \
  "$ROUTER_UI_TRUSTED_KEYS_FILE" > \
  "$CORE_ROOT/usr/share/premier-router/keys/trusted-keys.json"
chmod 644 "$CORE_ROOT/usr/share/premier-router/keys/trusted-keys.json"
jq -r '.keys[].public_key_path' "$ROUTER_UI_TRUSTED_KEYS_FILE" |
  while IFS= read -r repository_public_key; do
    runtime_name="$(basename "$repository_public_key")"
    copy_file "$ROUTER_UI_TRUST_ROOT/$repository_public_key" \
      "$CORE_ROOT/usr/share/premier-router/keys/release/$runtime_name" 644
  done
cat > "$CORE_ROOT/usr/share/premier-router/build-info" <<EOF
APP_VERSION=$APP_VERSION
PACKAGE_VERSION=$PKG_VERSION
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_DIRTY=$SOURCE_DIRTY
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
UPDATER_PROTOCOL=$UPDATER_PROTOCOL
RELEASE_KEY_ID=$RELEASE_KEY_ID
RELEASE_KEY_FINGERPRINT=$RELEASE_KEY_FINGERPRINT
EOF
chmod 644 "$CORE_ROOT/usr/share/premier-router/build-info"
if [ -n "${ROUTER_UI_DISPOSABLE_TEST_MARKER:-}" ]; then
  printf '%s' "$ROUTER_UI_DISPOSABLE_TEST_MARKER" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || {
    printf 'Disposable test marker is malformed\n' >&2
    exit 1
  }
  printf '%s\n' "$ROUTER_UI_DISPOSABLE_TEST_MARKER" > \
    "$CORE_ROOT/usr/share/premier-router/disposable-test-marker"
  chmod 644 "$CORE_ROOT/usr/share/premier-router/disposable-test-marker"
fi
mkdir -p "$CORE_ROOT/etc"
cat > "$CORE_ROOT/etc/vpn-ui-update.conf" <<'EOF'
AUTO_UPDATE='0'
AUTO_SCHEDULE='Sunday 04:17'
EOF
chmod 600 "$CORE_ROOT/etc/vpn-ui-update.conf"
write_legacy_manifest "$CORE_ROOT/usr/share/premier-router/legacy-files.list"
write_control \
  "premier-router-core" \
  "curl, jsonfilter, usign, nftables-json, coreutils-base64, socat, tailscale, xray-core" \
  "Premier Router 0.7.11 backend, signed updater, validator, rollback, and boot recovery." \
  "$CORE_CONTROL"
write_core_scripts "$CORE_CONTROL"

LUCI_ROOT="$BUILD_DIR/luci-app-premier-router/root"
LUCI_CONTROL="$BUILD_DIR/luci-app-premier-router/control"
copy_tree_file_modes "$ROOT_DIR/luci-vpn-ui/files/www" "$LUCI_ROOT/www"
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/share/luci/menu.d/luci-app-vpn-ui.json" "$LUCI_ROOT/usr/share/luci/menu.d/luci-app-vpn-ui.json" 644
copy_file "$ROOT_DIR/luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" "$LUCI_ROOT/usr/share/rpcd/acl.d/luci-app-vpn-ui.json" 644
write_control \
  "luci-app-premier-router" \
  "luci-base, rpcd, rpcd-mod-file, premier-router-core (= $PKG_VERSION)" \
  "Router UI 0.7.11 LuCI pages, RPC ACLs, menu entries, and canonical status include." \
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
  "$SETUP_ROOT/www/cgi-bin/firstboot-setup"
do
  [ -f "$executable" ] && chmod 755 "$executable"
done
write_control \
  "premier-router-setup" \
  "cgi-io, uhttpd, premier-router-core (= $PKG_VERSION)" \
  "Router UI 0.7.10-equivalent first-boot setup files for generated images." \
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
  gzip -n -c Packages > Packages.gz
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
