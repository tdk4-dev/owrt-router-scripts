#!/bin/sh
set -eu
umask 077

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FIRSTBOOT="$ROOT_DIR/image-overlay/www/cgi-bin/firstboot-setup"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/router-ui-firstboot-optional.XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT INT TERM

FIRSTBOOT_SETUP_LIB_ONLY=1 . "$FIRSTBOOT"

# The RD23/package path has no AdGuardHome binary or service. Skipping it must
# be a true no-op and the complete apply path must still finish.
ADGUARD_PROBE="$TMP_ROOT/adguard-probed"
adguard_available() { : > "$ADGUARD_PROBE"; return 1; }
configure_adguard false root secret-password ''
[ ! -e "$ADGUARD_PROBE" ]

STATE_DIR="$TMP_ROOT/state"
COMPLETE_FILE="$STATE_DIR/complete"
APPLY_LOCK="$STATE_DIR/apply.lock"
PAYLOAD="$TMP_ROOT/payload.json"
FILTERS_FILE="$TMP_ROOT/filters"
CONTENT_LENGTH=0
json_get() {
  case "$1" in
    '@.account.login') printf '%s\n' root ;;
    '@.account.password'|'@.account.passwordConfirm') printf '%s\n' secret-password ;;
    '@.account.authorizedKeys') printf '\n' ;;
    '@.vpn.enabled'|'@.adguard.enabled'|'@.tailscale.enabled') printf '%s\n' false ;;
    '@.vpn.vlessUrl'|'@.tailscale.authKey') printf '\n' ;;
    '@.tailscale.loginServer') printf '%s\n' https://headscale.example.invalid ;;
  esac
}
json_list() { :; }
configure_account() { [ "$1" = root ]; }
configure_network() { :; }
configure_vpn() { [ "$1" = false ]; }
configure_tailscale() { [ "$1" = false ]; }
header_json() { :; }
apply_result="$(apply_setup </dev/null)"
printf '%s' "$apply_result" | grep '"ok":true' >/dev/null
printf '%s' "$apply_result" | grep '"adguard":{"enabled":false,"available":false}' >/dev/null
[ -f "$COMPLETE_FILE" ]
[ -e "$ADGUARD_PROBE" ]

# Enabled AdGuardHome must fail closed when the package is absent.
adguard_failure="$(
  adguard_available() { return 1; }
  configure_adguard true root secret-password 1
)"
printf '%s' "$adguard_failure" | grep 'selected but is not installed' >/dev/null

# Tailscale logs are unique, live only in the declared runtime directory, and
# are removed before both success and failure return. Registration additionally
# requires BackendState=Running and a non-empty IPv4 address.
FIRSTBOOT_SETUP_LIB_ONLY=1 . "$FIRSTBOOT"
FIRSTBOOT_RUNTIME_DIR="$TMP_ROOT/runtime"
mkdir -p "$FIRSTBOOT_RUNTIME_DIR"
uci() { :; }
sleep() { :; }
jsonfilter() { printf '%s\n' Running; }
tailscale() {
  case "$1" in
    up) printf '%s\n' 'transient command output' ;;
    status) printf '%s\n' '{"BackendState":"Running"}' ;;
    ip) printf '%s\n' 100.64.0.9 ;;
  esac
}
configure_tailscale true https://headscale.example.invalid tskey-secret-rc9
[ -z "$(find "$FIRSTBOOT_RUNTIME_DIR" -type f -name 'firstboot-tailscale-up.*' -print)" ]
! grep -R 'tskey-secret-rc9' "$FIRSTBOOT_RUNTIME_DIR" >/dev/null 2>&1

tailscale() {
  case "$1" in
    status) printf '%s\n' '{"BackendState":"Running"}' ;;
    ip) return 0 ;;
  esac
}
! verify_tailscale_registration
tailscale() {
  case "$1" in
    status) printf '%s\n' '{"BackendState":"NeedsLogin"}' ;;
    ip) printf '%s\n' 100.64.0.9 ;;
  esac
}
jsonfilter() { printf '%s\n' NeedsLogin; }
! verify_tailscale_registration

tailscale_failure="$(
  tailscale() { [ "$1" != up ]; }
  configure_tailscale true https://headscale.example.invalid tskey-secret-fail
)"
printf '%s' "$tailscale_failure" | grep 'tailscale up failed' >/dev/null
[ -z "$(find "$FIRSTBOOT_RUNTIME_DIR" -type f -name 'firstboot-tailscale-up.*' -print)" ]
! grep -R 'tskey-secret-fail' "$FIRSTBOOT_RUNTIME_DIR" >/dev/null 2>&1

grep -F 'FIRSTBOOT_SETUP_LIB_ONLY' "$FIRSTBOOT" >/dev/null
grep -F 'BackendState=Running with a Tailscale IPv4 address' "$FIRSTBOOT" >/dev/null
grep -F 'firstboot-tailscale-up.$$' "$FIRSTBOOT" >/dev/null

printf '%s\n' 'Firstboot optional AdGuard and secret-safe registered Tailscale paths passed'
