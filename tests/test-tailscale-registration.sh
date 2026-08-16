#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PREMIER_ROUTER_HOST_TEST=1
VPN_UI_SOURCE_ONLY=1
export PREMIER_ROUTER_HOST_TEST VPN_UI_SOURCE_ONLY
. "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"

sleep() {
  :
}

VPN_UI_TEST_TAILSCALE_SNAPSHOT='pid=42
process_start_id=1001
enabled=true
backend=Running
ip4=100.64.0.10
control_url=https://control.example.invalid
tailnet=fixture
route_hash=route
rule_hash=rule
management_route_hash=management-route
management_rule_hash=management-rule
state_hash=state'
export VPN_UI_TEST_TAILSCALE_SNAPSHOT
tailscale_registration_ready

VPN_UI_TEST_TAILSCALE_SNAPSHOT='pid=42
process_start_id=1001
enabled=true
backend=NeedsLogin
ip4=
control_url=https://control.example.invalid
tailnet=
route_hash=route
rule_hash=rule
management_route_hash=management-route
management_rule_hash=management-rule
state_hash=state'
export VPN_UI_TEST_TAILSCALE_SNAPSHOT
if tailscale_registration_ready; then
  printf 'NeedsLogin was incorrectly accepted as a registered Tailscale state\n' >&2
  exit 1
fi

grep -q 'tailscale_registration_ready' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"
if grep -q '/tmp/vpn-ui-tailscale-up.log' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"; then
  printf 'fixed Tailscale auth log path must not retain registration output\n' >&2
  exit 1
fi
grep -Fq 'verify the login server, TLS, and preauth key' "$ROOT_DIR/luci-vpn-ui/files/usr/sbin/vpn-ui"

printf '%s\n' 'Tailscale registration-state preservation checks passed'
