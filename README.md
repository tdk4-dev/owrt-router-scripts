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

The custom x86/64 image includes LuCI, Xray, Tailscale, the VPN panel, and the
dark first-boot setup assistant. It boots its LAN at `10.77.0.1`. The first
page lets the owner choose the router hostname; the Wi-Fi page configures the
SSID, WPA mode, password, regulatory country, bands, channels, hidden-network
state, and client isolation when compatible radios are detected.

AdGuardHome is optional. If it is absent, the wizard shows current persistent
storage use plus an approximate installed-size segment and offers an explicit
install button. Projected storage use from 90% through 95% is warned; projected
use over 95% is blocked. Skipping it leaves DNS unchanged, and installation
never runs a global `opkg upgrade`.

Build it on an x86_64 Linux host:

```sh
./scripts/build-openwrt-ipks.sh
./build-openwrt-x86-fin0-image-linux.sh
```

The image script uses the official OpenWrt 24.10.5 ImageBuilder and installs
the already-built project IPKs into the image. It writes BIOS and EFI ext4
combined images to `dist/`.

Install a release image:

1. Download the matching `premier-router-*-openwrt-*.tar.gz` archive from the
   staged or published release directory.
2. Verify the archive:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

3. Extract the archive:

   ```sh
   tar -xzf premier-router-0.8.0-openwrt-24.10.5-x86-64.tar.gz
   ```

4. For x86/64 bare metal, write the EFI or BIOS `.img.gz` to the target SSD
   with a disk imaging tool, then boot the router and open:

   ```text
   http://10.77.0.1/
   ```

5. For VirtualBox testing, create a 64-bit Linux router VM and attach the
   extracted x86 disk image. Prove the customer path from a disposable client
   on an isolated VirtualBox LAN by opening `http://10.77.0.1/` or
   `http://10.77.0.1/setup/`. A NAT HTTP forward may also be used for a manual
   host-browser trial, but it does not prove customer LAN reachability.

For Xiaomi AX3000T / RD23 builds, choose the archive that matches the router's
boot layout:

- `xiaomi-ax3000t-openwrt-fin0` for the stock OpenWrt layout.
- `xiaomi-ax3000t-ubootmod-openwrt-fin0` for routers converted to OpenWrt's
  U-Boot layout.

RD23 images use the lean `image/openwrt-rd23-packages.txt` profile. They do not
include AdGuardHome, and first-boot setup hides and rejects that optional step
for the RD23 hardware profile. Its limited persistent flash is reserved for
the core router, LuCI, Xray, and update/support tooling. This is source/static
policy validation only until an RD23 is boot-tested; it is not a hardware claim.

Use LuCI or `sysupgrade` with the extracted factory/sysupgrade image that
matches the router's current installation method. Do not flash the ubootmod
image onto a stock-layout router unless it has been converted first.

The maintenance checklist for rebuilding and attaching images is in
[docs/custom-image-release-guide.md](docs/custom-image-release-guide.md).

### Package-First Updates

Starting with v0.8.0, running routers update through real OpenWrt packages
installed with `opkg`; release tarballs are legacy compatibility only.

Build local IPKs and an opkg feed:

```sh
./scripts/build-openwrt-ipks.sh
```

Stage a complete local release directory without publishing:

```sh
./scripts/stage-router-release.sh
```

Manual update on a router:

```sh
ROUTER_UI_VERSION=0.8.0 sh install-router-ui-release.sh
```

The installer downloads the release manifest, verifies the IPK checksums,
creates a full OpenWrt backup, migrates old tar.gz-installed files when
detected, installs only this project's packages, and validates the result. It
does not run global `opkg upgrade`.

Package installs keep non-secret installation/support metadata in
`/etc/config/premier_router`. Inspect the public-safe summary with:

```sh
vpn-ui router-metadata
vpn-ui footer-info
```

The LuCI Status Overview and VPN page show the Router Scripts version,
installation method, support level, registration state, and only a shortened
local router ID. The packages do not replace LuCI theme footer templates.

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
- explicit support level and registration/support metadata with no hidden tunnel
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
but package-first release installs and updates should use the staged IPKs.

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

## Development and Release Safety

Project workflow and release rules are documented in:

- [AGENTS.md](AGENTS.md)
- [docs/development-workflow.md](docs/development-workflow.md)
- [docs/custom-image-release-guide.md](docs/custom-image-release-guide.md)
- [docs/vm-release-testing-methodology.md](docs/vm-release-testing-methodology.md)
- [docs/customer-owner-policy.md](docs/customer-owner-policy.md)
- [docs/footer-branding.md](docs/footer-branding.md)

Do not publish a tag, GitHub Release, or release asset unless the current task
explicitly says `PUBLISH RELEASE <version>`.
