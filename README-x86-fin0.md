# OpenWrt x86 Router Setup

This is the router-side setup flow for a fresh OpenWrt 24.10.x x86/64 router PC.

It mirrors the main behavior of the current `openwrt-fin0` setup:

- LAN router at `10.20.0.1/24`.
- WAN on a chosen Ethernet device, either DHCP, static IPv4, or PPPoE.
- Dropbear SSH on TCP/22 with a root password and optional root public key.
- dnsmasq as LAN DHCP/DNS front door on port 53.
- AdGuardHome web UI on `http://10.20.0.1:3000`, DNS on `127.0.0.1:5353`.
- Xray VLESS TCP Reality Vision with SOCKS `10.20.0.1:11808`, HTTP `10.20.0.1:11809`, transparent TPROXY `:12345`.
- Russian/service domains routed direct by Xray.
- Tailscale/Headscale subnet route and exit-node advertisement.
- Tailscale exit-node traffic is captured by the same transparent Xray path.

The script does not clone personal DHCP reservations or WAN port forwards from the existing router. It has prompts for optional local DNS rewrites and extra direct IP/domain bypasses.

For an already running router, the LuCI VPN panel can be installed separately:

```sh
./install-openwrt-vpn-ui.sh
```

For a custom x86 image, use `luci-vpn-ui/files/` as an overlay and run
`/usr/sbin/vpn-ui init` after `/etc/xray/exit-st-cf.json` exists. See
[luci-vpn-ui/README.md](luci-vpn-ui/README.md).

## Script

Use:

```sh
setup-openwrt-x86-fin0.sh
```

Run it on the OpenWrt router itself:

```sh
sh /root/setup-openwrt-x86-fin0.sh
```

OpenWrt's admin SSH login is normally `root`. You do not need a separate login name unless you later install and manage Unix users yourself.

## Copying It To The Router

Best options:

1. Copy `setup-openwrt-x86-fin0.sh` to `/root/setup-openwrt-x86-fin0.sh` on the OpenWrt root filesystem if you mount the SSD from Linux.
2. Put the script on a FAT32 USB stick, boot OpenWrt, mount the stick, then copy it to `/root`.
3. After first boot, if SSH is reachable, avoid `scp`/SFTP and use `ssh cat`:

```sh
ssh root@192.168.1.1 'cat > /root/setup-openwrt-x86-fin0.sh && chmod +x /root/setup-openwrt-x86-fin0.sh' < setup-openwrt-x86-fin0.sh
ssh root@192.168.1.1 'sh /root/setup-openwrt-x86-fin0.sh'
```

If the router is already at `10.20.0.1`, replace `192.168.1.1` with `10.20.0.1`.

## Migrating An Already Configured Router

If the router was already set up before `vpn-routes` existed, use:

```sh
migrate-openwrt-vpn-routes.sh
```

Copy it without SFTP/SCP:

```sh
ssh owrt 'cat > /root/migrate-openwrt-vpn-routes.sh && chmod +x /root/migrate-openwrt-vpn-routes.sh' < migrate-openwrt-vpn-routes.sh
ssh owrt 'sh /root/migrate-openwrt-vpn-routes.sh'
```

Or without the SSH alias:

```sh
ssh root@10.20.0.1 'cat > /root/migrate-openwrt-vpn-routes.sh && chmod +x /root/migrate-openwrt-vpn-routes.sh' < migrate-openwrt-vpn-routes.sh
ssh root@10.20.0.1 'sh /root/migrate-openwrt-vpn-routes.sh'
```

The migration makes a backup before changing router config. It stores the latest backup path here:

```sh
/root/LAST_VPN_ROUTES_MIGRATION_BACKUP
```

Rollback command:

```sh
ssh owrt 'sh /root/rollback-vpn-routes-migration.sh'
```

Explicit rollback to the latest recorded archive:

```sh
ssh owrt 'sh /root/rollback-vpn-routes-migration.sh "$(cat /root/LAST_VPN_ROUTES_MIGRATION_BACKUP)"'
```

The backup archive includes `/etc/config`, `/etc/xray`, relevant init scripts, helper scripts, a state dump, and an OpenWrt `sysupgrade -b` config backup when `sysupgrade` is available.

## Before Running

Have these ready:

- VLESS Reality URL from 3x-ui, or UUID/public key/short ID/SNI/spiderX fields.
- Direct VPS IPv4 address. It must be a DNS-only A record, not a Cloudflare proxied IP.
- Tailscale or Headscale auth key if the router should login automatically.
- AdGuardHome web UI username/password.
- WAN mode for the friend's ISP: DHCP, static IPv4, or PPPoE.
- Which NIC is WAN and which NICs belong to the LAN bridge.

If the stock x86 image still has a tiny rootfs, the script stops before package install. Expand OpenWrt rootfs/overlay to the SSD, reboot, then rerun the script.

## Editing VPN Direct Routes

The setup installs a helper command:

```sh
vpn-routes
```

The direct-routing lists are plain text files:

```sh
/etc/xray/direct-domains.txt
/etc/xray/direct-ips.txt
```

Common edits:

```sh
vpn-routes list
vpn-routes add-domain example.ru
vpn-routes add-domain 'regexp:^.*\.example\.ru$'
vpn-routes add-domain geosite:alibaba
vpn-routes del-domain example.ru
vpn-routes edit domains
vpn-routes add-ip 203.0.113.10/32
vpn-routes del-ip 203.0.113.10/32
vpn-routes apply
```

`add-*`, `del-*`, and `edit` automatically run `vpn-routes apply`. `apply` regenerates `/etc/xray/exit-st-cf.json`, runs `xray run -test`, then restarts Xray and the transparent nft service only if the config is valid.
`geosite:*` domain rules require `geosite.dat` in the configured Xray datadir.

## Expected Checks

From a LAN client after setup:

```sh
curl -4 http://api.ipify.org
curl -4 -x socks5h://10.20.0.1:11808 http://api.ipify.org
```

Expected:

- Normal LAN traffic returns the VPS IP because transparent proxy is active.
- Explicit SOCKS also returns the VPS IP.
- Router direct curl, run on the router itself without SOCKS, returns the home ISP IP.
- Tailscale/Headscale must approve `0.0.0.0/0` and `10.20.0.0/24` for the node before phone/laptop exit-node traffic works.
