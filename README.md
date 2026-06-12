# OpenWrt Router Setup Scripts

For the new x86/64 router-PC setup, use [README-x86-fin0.md](README-x86-fin0.md) and [setup-openwrt-x86-fin0.sh](setup-openwrt-x86-fin0.sh).

## LuCI VPN Panel

Install the graphical VPN panel onto an already running OpenWrt router:

```sh
./install-openwrt-vpn-ui.sh
```

By default it connects to the `owrt` SSH alias, creates a full `sysupgrade -b`
backup, uploads `luci-vpn-ui/` over `ssh` + `tar`, runs the router-side
installer, and validates the rendered Xray config without changing the selected
profile.

Use Tailscale SSH:

```sh
ROUTER_HOST=owrt-ts ./install-openwrt-vpn-ui.sh
```

The panel source and image-overlay notes live in [luci-vpn-ui/README.md](luci-vpn-ui/README.md).

# Xiaomi RD23 VPN AP Setup

This repo contains a Mac-side setup script for Xiaomi RD23 / Xiaomi Mi Router AX3000T routers running OpenWrt.

The script automates the repeatable OpenWrt configuration:

- LAN `10.77.0.1/24`, WAN DHCP, DHCP/DNS for clients.
- Wi-Fi AP on 2.4 GHz and 5 GHz.
- Xray VLESS TCP Reality with explicit `flow=xtls-rprx-vision`.
- nft tproxy transparent proxy.
- Split tunneling: Russian domains, EMIAS, ESIA/Gosuslugi, private ranges, Tailscale, and the VLESS endpoint go direct.
- Tailscale/Headscale validation and optional first login via auth key.
- Tailnet SSH firewall rule for TCP/22 from `100.64.0.0/10`.
- Production cleanup: no `/etc/hosts` override for `tdk4.duckdns.org`.

## Boundary

The stock Xiaomi exploit/flashing step is not bundled. That part depends on Xiaomi firmware UI state and requires an admin password set in the Xiaomi web UI first.

Flow:

1. Plug Mac Ethernet into a Xiaomi LAN port.
2. Open Xiaomi web UI.
3. Complete initial setup and set the admin password.
4. Run your known RD23 OpenWrt exploit/flashing flow.
5. Run this script once OpenWrt root SSH is reachable.

## Usage

```sh
cp rd23.env.example rd23.env
```

Edit `rd23.env`, especially:

- `WIFI_PASSWORD`
- `VLESS_URL`
- `TAILSCALE_AUTHKEY` if the router is not already logged into Headscale

Then run:

```sh
set -a
source ./rd23.env
set +a
./setup-rd23-vpn-ap.sh
```

If OpenWrt is already at the final LAN address:

```sh
ROUTER_HOST=10.77.0.1 ./setup-rd23-vpn-ap.sh
```

If the router starts at OpenWrt default `192.168.1.1`, the script will configure `10.77.0.1`, restart networking, and wait for SSH at the new address. The Mac may need Ethernet DHCP renewal after that change.

## Expected Final Checks

On the router:

```sh
nslookup tdk4.duckdns.org
curl -4 http://api.ipify.org
curl -4 -x socks5h://10.77.0.1:11808 http://api.ipify.org
tailscale status
```

Expected:

- `tdk4.duckdns.org` resolves to the public home IP, not a home-LAN IP.
- direct router IP is the local ISP public IP.
- SOCKS/Xray IP is the VLESS server IP.
- Tailscale shows the router online.

From your admin machine:

```sh
ssh valera-owrt
```

## Notes

- Do not keep a static `/etc/hosts` mapping like `10.20.0.181 tdk4.duckdns.org` for production. It only works at home.
- The script uses `ssh cat > file` for file transfer; it does not use OpenWrt-incompatible SFTP `scp`.
- Router-side shell snippets are BusyBox `ash` compatible and avoid `timeout`, `nohup`, and GNU-only utilities.
