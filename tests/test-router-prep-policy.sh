#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CLI="$ROOT_DIR/image-overlay/usr/sbin/router-prep"
CGI="$ROOT_DIR/image-overlay/www/cgi-bin/router-prep"
PREP_DIR="$ROOT_DIR/image-overlay/www/prepare"
PKG_TEST="$ROOT_DIR/tests/test-openwrt-ipk-packages.sh"
PKG_BUILD="$ROOT_DIR/scripts/build-openwrt-ipks.sh"

[ -x "$CLI" ]
[ -x "$CGI" ]
[ -f "$PREP_DIR/index.html" ]
[ -f "$PREP_DIR/app.js" ]
[ -f "$PREP_DIR/styles.css" ]

grep -q 'STATE_DIR=.*etc/router-prep' "$CLI"
grep -q 'CUSTOMER_VPN' "$CLI"
grep -q 'SUPPORT_ACCESS' "$CLI"
grep -q 'SUPPORT_LEVEL' "$CLI"
grep -q 'REGISTRATION_STATE' "$CLI"
grep -q 'metadata-set' "$CLI"
grep -q 'metadata-sealed' "$CLI"
grep -q 'seal)' "$CLI"
grep -q 'unseal)' "$CLI"
grep -q 'placeholder-wifi' "$CLI"
grep -q 'ROUTER_PREP_BIN' "$CGI"
grep -q "api('authorize')" "$PREP_DIR/app.js"
grep -q "api('seal')" "$PREP_DIR/app.js"
grep -q 'router-prep token' "$PREP_DIR/app.js"
grep -q 'supportLevel' "$PREP_DIR/app.js"
grep -q 'registrationState' "$PREP_DIR/app.js"
grep -q 'www/cgi-bin/router-prep' "$PKG_BUILD"
grep -q 'usr/sbin/router-prep' "$PKG_BUILD"
grep -q 'www/prepare/app.js' "$PKG_TEST"
grep -q 'premier-router-setup/data/www/cgi-bin/router-prep' "$PKG_TEST"
grep -q 'premier-router-setup/data/usr/sbin/router-prep' "$PKG_TEST"

printf 'Router prep policy/source checks passed\n'
