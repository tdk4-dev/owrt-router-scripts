# LuCI VPN Panel

This directory contains a LuCI management suite for an already configured
OpenWrt/Xray/Tailscale router.

It installs:

- `/usr/sbin/vpn-ui` - authenticated helper used by LuCI.
- Versioned VPN, Tailscale, and Update LuCI JavaScript views. Versioned paths
  prevent an already-open browser session from retaining an older module.
- `/usr/share/luci/menu.d/luci-app-vpn-ui.json` - VPN, Tailscale, and
  top-level Update menu entries.
- `/usr/share/rpcd/acl.d/luci-app-vpn-ui.json` - rpcd ACL for the helper.

The panel imports the current `/etc/xray/exit-st-cf.json` VLESS Reality TCP
outbound on first run, stores saved profiles in `/etc/xray/vless-profiles.d/`,
stores the selected profile in `/etc/xray/vless-selected`, and manages editable
direct routing lists:

- `/etc/xray/direct-domains.txt`
- `/etc/xray/direct-ips.txt`

Domain rules are passed to Xray as domain matchers, so plain domains,
`regexp:*`, and `geosite:*` entries such as `geosite:alibaba` are supported.
`geosite:*` rules require `geosite.dat` in the Xray datadir, normally
`/usr/share/xray/geosite.dat`. The installer creates this file from the
v2fly/domain-list-community release `dlc.dat` when it is missing.

It also manages per-device VPN bypass state in:

- `/etc/xray/vpn-ui-device-bypass-macs.txt`

Active DHCP leases are read from `/tmp/dhcp.leases`. Devices marked disabled
are resolved from MAC address to their current IPv4 lease and placed in the
`vpn_ui_device_bypass4` nft set under `inet xray_transparent`, with an early
source-address accept rule in each prerouting chain.

Switching profiles or applying rules renders a temporary Xray JSON config,
runs `xray run -test -config ...`, then replaces `/etc/xray/exit-st-cf.json`
only after validation succeeds.

The global VPN toggle stops `xray-transparent` before stopping Xray, so clients
fall back to direct routing instead of being redirected into a stopped proxy.
Enabling starts Xray, restarts transparent routing, and reapplies device bypass
state.

## Subscriptions

The panel accepts HTTPS subscription URLs containing either plain newline
separated VLESS links or the common base64-encoded list format. Subscription
URLs are stored under `/etc/xray/subscriptions.d/` with mode `0600` and are
never returned to the browser after import.

Unsupported entries are skipped. Compatible VLESS Reality TCP profiles are
reconciled on refresh, while the currently selected profile is retained if a
provider temporarily removes it.

## Automatic Switching

Profiles can be selected for an explicit auto-switch pool.

- Failover mode checks the current endpoint over TCP once per minute and
  switches only after three consecutive failures.
- Periodic optimization defaults to every 12 hours and switches only when
  another pool member is at least 35% faster and improves latency by at least
  30 ms.

Both modes are disabled by default.

## Tailscale

`Network > Tailscale` is a dedicated panel; Tailscale controls no longer
appear in the VPN panel. It can connect, stop, restart, or log out and lists
all peers visible through `tailscale status --json`, including online state,
path, exit-node capability, and last-seen time. Each peer has an authenticated
Tailscale-layer ping action. Stopping preserves the current login state.
Preauth keys are passed directly to `tailscale up`, are not displayed again,
and are not stored by the panel.

## Install and update

[Premier Router 0.7.11](https://github.com/tdk4-dev/owrt-router-scripts/releases/tag/vpn-panel-v0.7.11)
is the stable package release for existing OpenWrt 24.10.5 x86/64. Use the
[installation and recovery guide](../docs/ordinary-user-ipk-installation.md)
to verify and install the signed assets or migrate from 0.7.10.

The LuCI **Update** page shows installed identity, transaction progress,
reboot status, and recovery actions. Signed package updates retain exact
project package bytes and supported application state for rollback. OpenWrt
dependency preparation is outside the package rollback transaction. The
0.7.11 release is manual-first. GitHub Latest and automatic discovery have a
separate rollout.

## Status Overview

`Status > Overview` includes a VPN service section with combined Xray and
transparent-routing health, selected profile, endpoint and server IP,
direct-domain rule count, and the selected server's cached connectivity ping.

## Custom Image Notes

For a future x86 OpenWrt image, the files under `luci-vpn-ui/files/` can be
used as an image overlay. The image still needs the base services/packages that
the current router already has:

- `luci`
- `rpcd-mod-file`
- `jsonfilter`
- `xray-core`
- the existing Xray transparent routing setup

Run `/usr/sbin/vpn-ui init` after the Xray config exists, or from a first-boot
script after router setup has rendered `/etc/xray/exit-st-cf.json`.
