# Install Premier Router 0.7.11

[Download the stable release](https://github.com/tdk4-dev/owrt-router-scripts/releases/tag/vpn-panel-v0.7.11).
Use it on existing **OpenWrt 24.10.5 x86/64**. The application version is
`0.7.11` and the opkg version is `0.7.11-1`. This package-only release has no
firmware images. Physical RD23, Factory commissioning, and other deployment
profiles require separate qualification. RD23 instructions in the signed
`INSTALLATION-RECOVERY.md` asset are historical candidate material.

This is a manual-first release. Select the explicit tag above. GitHub Latest
and automatic discovery remain on the previous release.

## Verify the assets

Download the attached assets into one directory. Obtain the
[production public key](https://github.com/tdk4-dev/owrt-router-scripts/blob/2ee70e7ef73b042fb8291c71aa30bad3d5a9f34f/release/keys/production-2026-07.pub)
from the pinned source and verify from the asset directory using a shell with
`usign` and `sha256sum`:

```sh
test "$(usign -F -p production-2026-07.pub)" = d055711acf1d9a5b &&
  usign -q -V -p production-2026-07.pub -m SHA256SUMS -x SHA256SUMS.sig &&
  sha256sum -c SHA256SUMS
```

Run an installer only after all checks succeed. Keep the verified files
together and transfer them over trusted access to the router.

## Clean installation

With LAN or console access, copy the following verified assets to a private
directory on the router:

- `bootstrap-router-ui-ipk-install.sh`
- `installed-manifest.json` and `installed-manifest.json.sig`
- `router-candidate-validator`
- `premier-router-core_0.7.11-1_all.ipk`
- `luci-app-premier-router_0.7.11-1_all.ipk`
- `premier-router-setup_0.7.11-1_all.ipk`

Use the signed OpenWrt feeds configured for 24.10.5 x86/64. As root, change
to the asset directory and run:

```sh
sh ./bootstrap-router-ui-ipk-install.sh "$PWD"
```

The bootstrap checks storage and package identity, backs up OpenWrt
configuration, and seeds a verified package restore point. After it completes,
reboot and sign in to LuCI from the LAN. Check that **Update** shows stable
`0.7.11` and opkg reports `0.7.11-1` for all three packages.

## Migrate an existing 0.7.10 installation

Keep LAN or console access. Copy the verified `rescue-router-ui.sh` from this
release to the router and run it as root:

```sh
sh ./rescue-router-ui.sh
```

The rescue prepares OpenWrt dependencies before starting the project package
transaction. Keep the rollback path printed by the script and the
`openwrt-configuration-recovery.tar.gz` file in the same transaction directory.
After the rescue succeeds, reboot and check **Update** or
`/usr/sbin/vpn-ui-update status` for the committed transaction. Verify the
previously configured VPN, DNS, routing, and Tailscale settings.

For recovery, use the active transaction's recorded rollback command and
configuration archive. Exact rollback covers the supported application
preimage and its state. OpenWrt prerequisites installed before the transaction
remain installed.

The tagged `stable-channel.json` is signed with the same key and binds the
SHA-256 of `router-release-manifest.json`. See the
[release scope and security remediation](router-ui-0.7.11-security.md).
