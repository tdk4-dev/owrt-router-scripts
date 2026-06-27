#!/bin/sh
set -eu

ROUTER_HOST="${ROUTER_HOST:-owrt-ts}"
ADMIN_TAILSCALE_IP="${ADMIN_TAILSCALE_IP:-100.64.0.3}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

cat > "$tmpdir/tailscale-route-guard" <<'EOF'
#!/bin/sh

ADMIN_TAILSCALE_IP="${ADMIN_TAILSCALE_IP:-100.64.0.3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
FAILURE_INTERVAL="${FAILURE_INTERVAL:-300}"

route_ok() {
  ip route get "$ADMIN_TAILSCALE_IP" 2>/dev/null |
    grep -q "dev tailscale0"
}

while :; do
  if tailscale ip -4 >/dev/null 2>&1 && ! route_ok; then
    logger -t tailscale-route-guard \
      "route to $ADMIN_TAILSCALE_IP is not using tailscale0; restarting tailscale"
    /etc/init.d/tailscale restart
    sleep 10

    if route_ok; then
      logger -t tailscale-route-guard \
        "restored route to $ADMIN_TAILSCALE_IP through tailscale0"
    else
      logger -t tailscale-route-guard \
        "route to $ADMIN_TAILSCALE_IP is still invalid after restart"
      sleep "$FAILURE_INTERVAL"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
EOF

cat > "$tmpdir/tailscale-route-guard.init" <<EOF
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

PROG=/usr/sbin/tailscale-route-guard

start_service() {
  procd_open_instance
  procd_set_param command "\$PROG"
  procd_set_param env ADMIN_TAILSCALE_IP="$ADMIN_TAILSCALE_IP"
  procd_set_param env CHECK_INTERVAL="60"
  procd_set_param env FAILURE_INTERVAL="300"
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF

ssh "$ROUTER_HOST" 'mkdir -p /usr/sbin'
ssh "$ROUTER_HOST" 'cat > /usr/sbin/tailscale-route-guard' \
  < "$tmpdir/tailscale-route-guard"
ssh "$ROUTER_HOST" 'cat > /etc/init.d/tailscale-route-guard' \
  < "$tmpdir/tailscale-route-guard.init"
ssh "$ROUTER_HOST" '
  set -e
  chmod 0755 /usr/sbin/tailscale-route-guard
  chmod 0755 /etc/init.d/tailscale-route-guard
  sh -n /usr/sbin/tailscale-route-guard
  sh -n /etc/init.d/tailscale-route-guard
  /etc/init.d/tailscale-route-guard enable
  /etc/init.d/tailscale-route-guard stop >/dev/null 2>&1 || true
  /etc/init.d/tailscale-route-guard start
'

echo "Installed Tailscale route guard on $ROUTER_HOST for $ADMIN_TAILSCALE_IP."
