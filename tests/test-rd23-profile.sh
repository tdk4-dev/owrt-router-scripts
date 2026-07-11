#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGES="$ROOT_DIR/image/openwrt-rd23-packages.txt"
SETUP="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
APP="$ROOT_DIR/firstboot-wizard/www/app.js"
PREP="$ROOT_DIR/image-overlay/usr/sbin/router-prep"

[ -f "$PACKAGES" ]
if awk 'NF && $1 !~ /^#/ { print $1 }' "$PACKAGES" | grep -Eqi '(^|-)adguard(home)?$'; then
  printf 'RD23 image profile must not include AdGuardHome\n' >&2
  exit 1
fi
grep -q 'xiaomi-ax3000t-rd23' "$SETUP"
grep -q 'adguard_allowed_for_hardware' "$SETUP"
grep -q 'steps.splice(adguardStep, 1)' "$APP"
grep -q 'AdGuardHome is deferred for Xiaomi AX3000T/RD23' "$PREP"
grep -q 'openwrt-rd23-packages.txt' "$ROOT_DIR/README.md"
grep -q 'excludes AdGuardHome' "$ROOT_DIR/docs/custom-image-release-guide.md"

printf 'RD23 lean package and AdGuard deferral checks passed\n'
