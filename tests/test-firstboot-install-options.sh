#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SETUP="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"

FIRSTBOOT_SETUP_LIB_ONLY=1 . "$SETUP"

df() {
  case "$1" in -Pk) ;; *) return 1 ;; esac
  printf '%s\n' \
    'Filesystem 1024-blocks Used Available Capacity Mounted on' \
    "/dev/test ${TEST_TOTAL_KB:?} ${TEST_USED_KB:?} $((TEST_TOTAL_KB - TEST_USED_KB)) 0% /overlay"
}

TEST_TOTAL_KB=102400
TEST_USED_KB=51200
measure_adguard_storage 33554432
[ "$ADGUARD_STORAGE_RISK" = safe ]
[ "$ADGUARD_CAN_INSTALL" = true ]

TEST_USED_KB=61440
measure_adguard_storage 33554432
[ "$ADGUARD_STORAGE_RISK" = warning ]
[ "$ADGUARD_CAN_INSTALL" = true ]

TEST_USED_KB=66560
measure_adguard_storage 33554432
[ "$ADGUARD_STORAGE_RISK" = blocked ]
[ "$ADGUARD_CAN_INSTALL" = false ]

validate_router_hostname 'premier-router-01'
invalid_hostname="$(validate_router_hostname '-unsafe-name')"
printf '%s\n' "$invalid_hostname" | grep -Fq 'cannot begin or end with a hyphen'

grep -q 'adguard-install) install_adguard' "$SETUP"
grep -q 'opkg install "$ADGUARD_PACKAGE"' "$SETUP"
grep -A4 'if adguard_available; then' "$SETUP" | grep -q 'measure_adguard_storage 0'
if grep -Eq 'opkg[[:space:]]+upgrade' "$SETUP"; then
  printf 'first-boot setup must not run a global opkg upgrade\n' >&2
  exit 1
fi
grep -q 'verify_tailscale_registration' "$SETUP"
grep -q "json_get '@.router.hostname'" "$SETUP"

printf '%s\n' 'First-boot hostname, AdGuard storage, and Tailscale policy checks passed'
