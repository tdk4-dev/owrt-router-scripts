# LuCI VPN Panel

This directory contains a small LuCI panel for an already configured
OpenWrt/Xray router.

It installs:

- `/usr/sbin/vpn-ui` - authenticated helper used by LuCI.
- `/www/luci-static/resources/view/network/vpn.js` - LuCI JavaScript view.
- `/usr/share/luci/menu.d/luci-app-vpn-ui.json` - `Network > VPN` menu entry.
- `/usr/share/rpcd/acl.d/luci-app-vpn-ui.json` - rpcd ACL for the helper.

The panel imports the current `/etc/xray/exit-st-cf.json` VLESS Reality TCP
outbound on first run, stores saved profiles in `/etc/xray/vless-profiles.d/`,
stores the selected profile in `/etc/xray/vless-selected`, and manages editable
direct routing lists:

- `/etc/xray/direct-domains.txt`
- `/etc/xray/direct-ips.txt`

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

## Install to a Running Router

From the repo root:

```sh
./install-openwrt-vpn-ui.sh
```

Use another SSH alias:

```sh
ROUTER_HOST=owrt-ts ./install-openwrt-vpn-ui.sh
```

The host-side installer uses `ssh` and `tar` instead of `scp`, because the
target router may not have an SFTP server. It creates a full OpenWrt
`sysupgrade -b` backup before installing unless `MAKE_SYSUPGRADE_BACKUP=0` is
set.

## Router-Side Installer

`install.sh` is intended to run on the router after the directory is uploaded.
It creates `/root/vpn-ui-preinstall-<timestamp>/` and:

```sh
/root/rollback-vpn-ui.sh
```

Rollback restores all touched files, clears LuCI menu cache, restarts
`rpcd`/`uhttpd`, validates the restored Xray config, and restarts Xray.

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
