#!/usr/bin/env bash
set -euo pipefail

# Apply OpenWrt-style split tunneling to relay-ru1-yc's Tailscale exit node.
#
# Scope:
#   - only packets entering relay-ru1-yc from tailscale0 are affected
#   - default exit traffic still uses wg-relay0/table 10088
#   - direct IP/domain matches use the relay main table/eth0
#   - existing x-ui/Xray/WireGuard config files are not modified

OWRT_HOST="${OWRT_HOST:-owrt}"
RELAY_HOST="${RELAY_HOST:-relay-ru1-yc}"
DIRECT_DOMAINS_SOURCE="${DIRECT_DOMAINS_SOURCE:-}"
DIRECT_IPS_SOURCE="${DIRECT_IPS_SOURCE:-}"

TS_IF="${TS_IF:-tailscale0}"
WG_IF="${WG_IF:-wg-relay0}"
WG_SRC="${WG_SRC:-10.88.0.3}"
WG_TABLE="${WG_TABLE:-10088}"
WG_RULE_PRIO="${WG_RULE_PRIO:-5280}"
DIRECT_MARK="${DIRECT_MARK:-0x01000000}"
DIRECT_MARK_MASK="${DIRECT_MARK_MASK:-0x01000000}"
DIRECT_RULE_PRIO="${DIRECT_RULE_PRIO:-5275}"
DNS_PORT="${DNS_PORT:-1053}"
NFT_TABLE="${NFT_TABLE:-tailscale_exit_split}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

log() {
  printf '==> %s\n' "$*" >&2
}

remote_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

if [ -n "$DIRECT_DOMAINS_SOURCE" ] && [ -n "$DIRECT_IPS_SOURCE" ]; then
  log "Reading split route files from local sources"
  cp "$DIRECT_DOMAINS_SOURCE" "$tmpdir/direct-domains.txt"
  cp "$DIRECT_IPS_SOURCE" "$tmpdir/direct-ips.txt"
else
  log "Reading OpenWrt split route files from ${OWRT_HOST}"
  ssh "$OWRT_HOST" 'cat /etc/xray/direct-domains.txt' > "$tmpdir/direct-domains.txt"
  ssh "$OWRT_HOST" 'cat /etc/xray/direct-ips.txt' > "$tmpdir/direct-ips.txt"
fi

# The FIN egress provider blocks outbound mail ports (25/465/587/993/995), so
# Gmail IMAP/SMTP/POP cannot traverse the default wg-relay0/FIN exit. Force Gmail
# onto the direct (Russian eth0) egress, which reaches Google mail normally.
if ! grep -qix 'gmail.com' "$tmpdir/direct-domains.txt"; then
  printf 'gmail.com\n' >> "$tmpdir/direct-domains.txt"
fi

log "Rendering dnsmasq nftset rules"
NFT_TABLE="$NFT_TABLE" perl -ne '
  chomp;
  s/^\s+|\s+$//g;
  next if $_ eq "" || /^#/;

  if (/^geosite:/) {
    print "# unsupported-by-dnsmasq $_\n";
    next;
  }

  if (/^regexp:\^\.\*\\\.(.+)\$$/) {
    my $d = $1;
    $d =~ s/\\\././g;
    print "nftset=/$d/4#inet#$ENV{NFT_TABLE}#direct4_dns\n";
    next;
  }

  s/^domain://;
  s/^full://;
  next if /[:*]/;
  print "nftset=/$_/4#inet#$ENV{NFT_TABLE}#direct4_dns\n";
' "$tmpdir/direct-domains.txt" > "$tmpdir/dnsmasq-nftsets.conf"

log "Installing dnsmasq-base on ${RELAY_HOST} if needed"
ssh "$RELAY_HOST" '
  set -e
  if ! command -v dnsmasq >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y dnsmasq-base
  fi
'

log "Uploading split-tunnel data files"
ssh "$RELAY_HOST" 'sudo install -d -m 0755 /etc/tailscale-exit-split'
ssh "$RELAY_HOST" 'sudo tee /etc/tailscale-exit-split/direct-domains.txt >/dev/null' < "$tmpdir/direct-domains.txt"
ssh "$RELAY_HOST" 'sudo tee /etc/tailscale-exit-split/direct-ips.txt >/dev/null' < "$tmpdir/direct-ips.txt"
ssh "$RELAY_HOST" 'sudo tee /etc/tailscale-exit-split/dnsmasq-nftsets.conf >/dev/null' < "$tmpdir/dnsmasq-nftsets.conf"

log "Installing relay-side routing and DNS services"
ssh "$RELAY_HOST" "sudo tee /usr/local/sbin/tailscale-exit-wg-relay0.sh >/dev/null" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TS_IF="$TS_IF"
WG_IF="$WG_IF"
WG_SRC="$WG_SRC"
WG_TABLE="$WG_TABLE"
WG_RULE_PRIO="$WG_RULE_PRIO"
DIRECT_RULE_PRIO="$DIRECT_RULE_PRIO"
DIRECT_MARK="$DIRECT_MARK"
DIRECT_MARK_MASK="$DIRECT_MARK_MASK"
DNS_PORT="$DNS_PORT"
NFT_TABLE="$NFT_TABLE"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf."\${TS_IF}".rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf."\${WG_IF}".rp_filter=0 >/dev/null 2>&1 || true

ip route replace default dev "\${WG_IF}" table "\${WG_TABLE}" src "\${WG_SRC}"

while ip rule del priority "\${DIRECT_RULE_PRIO}" fwmark "\${DIRECT_MARK}/\${DIRECT_MARK_MASK}" table main 2>/dev/null; do :; done
ip rule add priority "\${DIRECT_RULE_PRIO}" fwmark "\${DIRECT_MARK}/\${DIRECT_MARK_MASK}" table main

while ip rule del priority "\${WG_RULE_PRIO}" iif "\${TS_IF}" table "\${WG_TABLE}" 2>/dev/null; do :; done
ip rule add priority "\${WG_RULE_PRIO}" iif "\${TS_IF}" table "\${WG_TABLE}"

nft delete table inet "\${NFT_TABLE}" 2>/dev/null || true
nft add table inet "\${NFT_TABLE}"
nft 'add set inet '"\${NFT_TABLE}"' direct4_static { type ipv4_addr; flags interval; }'
nft 'add set inet '"\${NFT_TABLE}"' direct4_dns { type ipv4_addr; flags interval; timeout 6h; }'
nft 'add chain inet '"\${NFT_TABLE}"' dns_prerouting { type nat hook prerouting priority dstnat; policy accept; }'
nft 'add chain inet '"\${NFT_TABLE}"' mark_prerouting { type filter hook prerouting priority -151; policy accept; }'

static_ranges="\$(awk '
  BEGIN {
    print "0.0.0.0/8";
    print "10.0.0.0/8";
    print "100.64.0.0/10";
    print "127.0.0.0/8";
    print "169.254.0.0/16";
    print "172.16.0.0/12";
    print "192.168.0.0/16";
    print "224.0.0.0/4";
    print "240.0.0.0/4";
    print "78.17.16.62/32";
    print "95.165.15.222/32";
    print "89.125.81.42/32";
    # Ozon AS44386 currently announces this server block. Keep it static so
    # cached client connections cannot bypass the DNS-populated direct set.
    print "185.73.192.0/22";
  }
  /^[[:space:]]*(#|$)/ { next }
  { print \$1 }
' /etc/tailscale-exit-split/direct-ips.txt | sort -u | paste -sd, -)"

if [ -n "\${static_ranges}" ]; then
  nft add element inet "\${NFT_TABLE}" direct4_static "{ \${static_ranges} }"
fi

nft add rule inet "\${NFT_TABLE}" dns_prerouting iifname "\${TS_IF}" udp dport 53 counter redirect to :"\${DNS_PORT}"
nft add rule inet "\${NFT_TABLE}" dns_prerouting iifname "\${TS_IF}" tcp dport 53 counter redirect to :"\${DNS_PORT}"
nft add rule inet "\${NFT_TABLE}" mark_prerouting iifname "\${TS_IF}" ip daddr @direct4_static counter meta mark set mark or "\${DIRECT_MARK}"
nft add rule inet "\${NFT_TABLE}" mark_prerouting iifname "\${TS_IF}" ip daddr @direct4_dns counter meta mark set mark or "\${DIRECT_MARK}"
# AdminVPS globally blocks outbound TCP 8080 in the FIN/NL locations. Ookla
# Speedtest uses TCP 8080 for latency/test servers, so force that port through
# RU1's direct eth0 egress for Tailscale exit-node clients.
nft add rule inet "\${NFT_TABLE}" mark_prerouting iifname "\${TS_IF}" tcp dport 8080 counter meta mark set mark or "\${DIRECT_MARK}"
EOF

ssh "$RELAY_HOST" "sudo tee /etc/tailscale-exit-split/dnsmasq.conf >/dev/null" <<EOF
port=$DNS_PORT
bind-dynamic
interface=$TS_IF
listen-address=100.64.0.27
no-dhcp-interface=$TS_IF
no-resolv
strict-order
# Resolve exit traffic from the FIN egress vantage (queries sourced via wg-relay0)
# so CDN/anycast answers are reachable from the FIN exit. Resolving locally in
# Russia returned Russia-optimized CDN IPs that the FIN exit cannot reach
# (e.g. Apple Music "resource unavailable").
server=1.1.1.1@$WG_SRC
server=9.9.9.9@$WG_SRC
# Gmail egresses Russia (FIN provider blocks mail ports); resolve it from the
# local Russian resolver to keep its DNS vantage aligned with its egress.
server=/gmail.com/127.0.0.53
cache-size=10000
conf-file=/etc/tailscale-exit-split/dnsmasq-nftsets.conf
EOF

ssh "$RELAY_HOST" "sudo tee /etc/systemd/system/tailscale-exit-dnsmasq.service >/dev/null" <<'EOF'
[Unit]
Description=DNS helper for Tailscale exit split-tunnel nftsets
After=network-online.target tailscaled.service systemd-resolved.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/tailscale-exit-split/dnsmasq.conf --pid-file=/run/tailscale-exit-dnsmasq.pid
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

ssh "$RELAY_HOST" "sudo tee /etc/systemd/system/tailscale-exit-wg-relay0.service >/dev/null" <<'EOF'
[Unit]
Description=Route Tailscale IPv4 exit-node traffic through wg-relay0 with split tunneling
After=network-online.target tailscaled.service wg-quick@wg-relay0.service
Wants=network-online.target
Requires=tailscaled.service wg-quick@wg-relay0.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-exit-wg-relay0.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

ssh "$RELAY_HOST" "sudo tee /etc/sysctl.d/99-tailscale-exit-wg-relay0.conf >/dev/null" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

log "Validating and starting services"
ssh "$RELAY_HOST" '
  set -e
  sudo chmod 0755 /usr/local/sbin/tailscale-exit-wg-relay0.sh
  sudo /usr/local/sbin/tailscale-exit-wg-relay0.sh
  sudo dnsmasq --test --conf-file=/etc/tailscale-exit-split/dnsmasq.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now tailscale-exit-wg-relay0.service
  sudo systemctl enable --now tailscale-exit-dnsmasq.service
  sudo systemctl restart tailscale-exit-wg-relay0.service
  sudo systemctl restart tailscale-exit-dnsmasq.service
  systemctl is-active tailscale-exit-wg-relay0.service
  systemctl is-active tailscale-exit-dnsmasq.service
'

log "Verification"
ssh "$RELAY_HOST" '
  set -e
  echo "default exit route:"
  ip route get 1.1.1.1 from 100.64.0.1 iif tailscale0
  echo "marked/direct route:"
  ip route get 5.35.125.12 from 100.64.0.1 iif tailscale0 mark 0x01000000
  echo "direct DNS population test:"
  dig @100.64.0.27 -p 1053 ya.ru +short || true
  sudo nft list table inet tailscale_exit_split
'

log "Done"
