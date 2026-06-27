# OpenWrt Router Setup Scripts

Reusable scripts for configuring OpenWrt routers with LuCI, Xray/VLESS Reality,
transparent routing, direct-route lists, and optional Tailscale/Headscale.

## x86 Router Setup

For the x86/64 router-PC setup, use:

- [README-x86-fin0.md](README-x86-fin0.md)
- [setup-openwrt-x86-fin0.sh](setup-openwrt-x86-fin0.sh)

`openwrt-fin0` is the default example hostname used by that flow. Override it
with `HOSTNAME` or `TAILSCALE_HOSTNAME` for your own deployment.

### Custom Installation Image

The custom x86/64 image includes LuCI, AdGuardHome, Xray, Tailscale, the VPN
panel, and the dark first-boot setup assistant. It boots its LAN at
`10.77.0.1`.

Build it on an x86_64 Linux host:

```sh
./build-openwrt-x86-fin0-image-linux.sh
```

The script uses the official OpenWrt 24.10.5 ImageBuilder and writes BIOS and
EFI ext4 combined images to `dist/`.

### Owner Preparation Panel

The custom image includes a preparation panel that is separate from the
customer first-boot wizard. Retrieve its temporary token over a trusted SSH or
local console session:

```sh
router-prep token
```

Then open:

```text
http://10.77.0.1/prepare/#token=TOKEN
```

The panel provides:

- WAN, DNS, SSH, Xray, AdGuard, and Tailscale health checks
- simulated 2.4 and 5 GHz radios for previewing the complete Wi-Fi wizard
- owner Headscale/Tailscale enrollment without exposing the preauth key later
- customer access policy for VPN, Tailscale, updates, packages, and AdGuard
- verified pre-handoff `sysupgrade` backups
- a seal action that removes preview radios and disables the preparation API

After sealing, the preparation panel can only be reopened from SSH or the
local console:

```sh
router-prep unseal
router-prep token
```

## LuCI VPN Panel

Install the graphical VPN panel onto an already running OpenWrt router:

```sh
./install-openwrt-vpn-ui.sh
```

By default it connects to the `owrt` SSH alias, creates a full `sysupgrade -b`
backup, uploads the local panel bundle, runs the router-side installer, and
validates the rendered Xray config without changing the selected profile.

Use another SSH target:

```sh
ROUTER_HOST=root@192.168.1.1 ./install-openwrt-vpn-ui.sh
```

To install the same VPN and Tailscale panels on a friend's already configured
OpenWrt router:

```sh
./install-friend-vpn-panel.sh valera-owrt
```

The friend installer checks prerequisites, creates and downloads a full
OpenWrt backup, preserves existing VPN state, installs both
`Network > VPN Panel` and `Network > Tailscale`, adds a top-level `Update`
menu, and validates the result.

The older raw-branch bootstrap remains available with `PANEL_SOURCE=github`,
but normal installs and updates use bundles.

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
