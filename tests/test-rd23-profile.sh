#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGES="$ROOT_DIR/image/openwrt-rd23-packages.txt"

[ -f "$PACKAGES" ]
package_names="$(awk 'NF && $1 !~ /^#/ { print $1 }' "$PACKAGES")"
printf '%s\n' "$package_names" | grep -Eqi '(^|-)adguard(home)?$' && {
  printf 'RD23 image profile must not include AdGuardHome\n' >&2
  exit 1
}
printf '%s\n' "$package_names" | grep -qx 'luci-app-package-manager' && {
  printf 'RD23 image profile must not import the deferred package-manager surface\n' >&2
  exit 1
}
printf '%s\n' "$package_names" | grep -qx 'dnsmasq-full' && {
  printf 'RD23 image profile must preserve the current-main DNS package boundary\n' >&2
  exit 1
}
for package in coreutils-nohup ucode ucode-mod-fs usign; do
  printf '%s\n' "$package_names" | grep -qx "$package" || {
    printf 'RD23 updater dependency is missing: %s\n' "$package" >&2
    exit 1
  }
done
grep -q 'Lean OpenWrt 24.10.5 package set' "$PACKAGES"
grep -q 'AdGuardHome and the LuCI package manager are intentionally deferred' "$PACKAGES"

printf 'RD23 lean package boundary and updater dependencies preserved\n'
