#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$ROOT_DIR/firstboot-wizard/www/app.js"
SERVER="$ROOT_DIR/firstboot-wizard/server.mjs"
CGI="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

grep -Fq "This image uses OpenWrt's root account for SSH and LuCI administration." "$APP"
grep -Fq 'Administrator account' "$APP"
grep -Fq "state.form.account.login = 'root'" "$APP"
! grep -Fq "path: 'account.login'" "$APP"
! grep -Fq "id: 'account-login'" "$APP"
grep -Fq 'The administrator account is fixed to root on this OpenWrt image.' "$SERVER"
grep -Fq 'The administrator account is fixed to root on this OpenWrt image.' "$CGI"
grep -Fq 'passwd root' "$CGI"

printf 'Firstboot root-only administrator checks passed\n'
