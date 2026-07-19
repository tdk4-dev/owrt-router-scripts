#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VPN_UI_LIB_ONLY=1 . "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"

MOCK_BACKEND=Running
MOCK_IP=100.64.0.10

tailscale() {
  case "${1:-}" in
    status) printf '%s\n' '{"BackendState":"mock"}' ;;
    ip) [ -n "$MOCK_IP" ] && printf '%s\n' "$MOCK_IP" ;;
    *) return 1 ;;
  esac
}

jsonfilter() {
  printf '%s\n' "$MOCK_BACKEND"
}

sleep() {
  :
}

tailscale_registration_ready

MOCK_BACKEND=NeedsLogin
MOCK_IP=''
if tailscale_registration_ready; then
  printf 'NeedsLogin was incorrectly accepted as a registered Tailscale state\n' >&2
  exit 1
fi

grep -q 'tailscale_registration_ready' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
if grep -q '/tmp/vpn-ui-tailscale-up.log' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"; then
  printf 'fixed Tailscale auth log path must not retain registration output\n' >&2
  exit 1
fi

printf '%s\n' 'Tailscale registration-state verification checks passed'
