# OpenWrt Router Setup Scripts

Reusable scripts for configuring OpenWrt routers with LuCI, Xray/VLESS Reality,
transparent routing, direct-route lists, and optional Tailscale/Headscale.

## x86 Router Setup

For the x86/64 router-PC setup, use:

- [README-x86-fin0.md](README-x86-fin0.md)
- [setup-openwrt-x86-fin0.sh](setup-openwrt-x86-fin0.sh)

`openwrt-fin0` is the default example hostname used by that flow. Override it
with `HOSTNAME` or `TAILSCALE_HOSTNAME` for your own deployment.

## LuCI VPN Panel

Install the graphical VPN panel onto an already running OpenWrt router:

```sh
./install-openwrt-vpn-ui.sh
```

By default it connects to the `owrt` SSH alias, creates a full `sysupgrade -b`
backup, downloads the panel files from the configured GitHub branch on the
router, runs the router-side installer, and validates the rendered Xray config
without changing the selected profile.

Use another SSH target:

```sh
ROUTER_HOST=root@192.168.1.1 ./install-openwrt-vpn-ui.sh
```

Install unpushed local edits instead of the branch copy:

```sh
PANEL_SOURCE=local ./install-openwrt-vpn-ui.sh
```

The default branch source is
`tdk4-dev/owrt-router-scripts@codex/vpn-panel-installer`. Override with
`GITHUB_REPO`, `GITHUB_BRANCH`, or `GITHUB_REF`.

The installer also installs Xray geosite data at `/usr/share/xray/geosite.dat`
when it is missing, so `geosite:*` direct routing rules work by default. It
does not refresh an existing geosite database unless `UPDATE_GEOSITE=1` is set.

The panel source and image-overlay notes live in
[luci-vpn-ui/README.md](luci-vpn-ui/README.md).

## Xiaomi RD23 VPN AP Setup

For Xiaomi RD23 / AX3000T routers already running OpenWrt, use:

- [rd23.env.example](rd23.env.example)
- [setup-rd23-vpn-ap.sh](setup-rd23-vpn-ap.sh)

```sh
cp rd23.env.example rd23.env
```

Edit `rd23.env`, especially:

- `WIFI_PASSWORD`
- `VLESS_URL`
- `HEADSCALE_URL`, `TAILSCALE_HOSTNAME`, and `TAILSCALE_AUTHKEY` if using
  Headscale/Tailscale login from the script

Then run:

```sh
set -a
source ./rd23.env
set +a
./setup-rd23-vpn-ap.sh
```

## Notes

- Do not commit real VLESS links, auth keys, private domains, or local device
  addresses.
- Use `.env`/local config files for deployment-specific values.
- File transfer to OpenWrt uses `ssh` + `cat` or `ssh` + `tar`, avoiding
  OpenWrt-incompatible SFTP assumptions.
