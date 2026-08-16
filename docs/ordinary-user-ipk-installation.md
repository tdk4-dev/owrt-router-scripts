# Installing Router UI 0.7.11 on an existing RD23

> **Pre-publication RC16 guidance — not an installation authorization.** Use
> this document only after the separately authorized published release supplies
> the exact signed manifest, filenames, sizes, hashes, and storage gates.

This is the preferred path for a Xiaomi RD23 that already runs clean OpenWrt
installed with XMiR. It installs three hardware-independent packages and does
not replace the router firmware or boot layout.

The signed bootstrap accepts OpenWrt `24.10.0` through `24.10.99` on
`mediatek/filogic` (RD23) or `x86/64`. It refuses other releases and targets
before changing packages.

The active candidate displays `0.7.11-rc.16` on the candidate channel. The
OpenWrt packages use `0.7.11~rc16-1`. Supported RC14 and RC15 protocol-2
installations can accept this candidate only after a canonical signed RC16
artifact set exists. No such bytes are implied by this source document.

Do this over Ethernet from the LAN side. Do not perform the installation over
the VPN, Tailscale, or Wi-Fi path that you are changing.

## 1. Record the router state and make an off-router backup

Run these commands from the administrator's workstation. Replace
`ROUTER_ADDRESS` with the router's LAN address:

```sh
ssh root@ROUTER_ADDRESS 'ubus call system board; free -m; df -h /overlay /tmp; \
  opkg status xray-core tailscale 2>/dev/null; \
  /etc/init.d/xray enabled 2>/dev/null && echo xray_enabled=yes || true; \
  /etc/init.d/tailscale enabled 2>/dev/null && echo tailscale_enabled=yes || true; \
  logread | tail -n 120'

ssh root@ROUTER_ADDRESS \
  'sysupgrade -b /tmp/router-before-0.7.11.tar.gz'
ssh root@ROUTER_ADDRESS \
  'cat /tmp/router-before-0.7.11.tar.gz' \
  > router-before-0.7.11.tar.gz
test -s router-before-0.7.11.tar.gz
tar -tzf router-before-0.7.11.tar.gz >/dev/null
router_backup_sha="$(ssh root@ROUTER_ADDRESS \
  "sha256sum /tmp/router-before-0.7.11.tar.gz | awk '{print \$1}'")"
local_backup_sha="$(shasum -a 256 router-before-0.7.11.tar.gz | awk '{print $1}')"
test -n "$router_backup_sha"
test "$local_backup_sha" = "$router_backup_sha"
```

The archive listing and the router/local SHA-256 comparison must both pass.
Keep that backup private: it can contain network and VPN credentials. Stop and
ask for help if `/overlay` is nearly full, `/tmp` cannot hold the downloaded
files, or the log contains recent out-of-memory kills. Do not flash an image to
work around those symptoms.

Because this router is being tested specifically with both Xray and Tailscale,
record their enabled/running state and stop them temporarily before installing.
Do not disable either service; the reboot after installation will restore every
service that was already enabled:

```sh
ssh root@ROUTER_ADDRESS '
  for service in xray-exit-st xray-transparent xray tailscale; do
    [ -x "/etc/init.d/$service" ] || continue
    /etc/init.d/$service enabled && enabled=yes || enabled=no
    /etc/init.d/$service running && running=yes || running=no
    echo "$service enabled=$enabled running=$running"
  done
  for service in xray-exit-st xray-transparent xray tailscale; do
    [ -x "/etc/init.d/$service" ] || continue
    /etc/init.d/$service stop
  done'
```

Stay connected over wired LAN after this point. If stopping a service affects
the management path, stop and reconnect locally before continuing.

## 2. Copy the signed RC16 package set and first-install bootstrap

Place these ten release files in one directory on the workstation:

```text
production-2026-07.pub
SHA256SUMS
SHA256SUMS.sig
premier-router-core_0.7.11~rc16-1_all.ipk
luci-app-premier-router_0.7.11~rc16-1_all.ipk
premier-router-setup_0.7.11~rc16-1_all.ipk
installed-manifest.json
installed-manifest.json.sig
router-candidate-validator
bootstrap-router-ui-ipk-install.sh
```

Copy them using a method compatible with the router's Dropbear SSH server:

```sh
for file in \
  production-2026-07.pub SHA256SUMS SHA256SUMS.sig \
  premier-router-core_0.7.11~rc16-1_all.ipk \
  luci-app-premier-router_0.7.11~rc16-1_all.ipk \
  premier-router-setup_0.7.11~rc16-1_all.ipk \
  installed-manifest.json installed-manifest.json.sig \
  router-candidate-validator bootstrap-router-ui-ipk-install.sh
do
  ssh root@ROUTER_ADDRESS "umask 077; cat > '/tmp/$file'" < "./$file"
done
```

## 3. Verify before installing

Run on the router:

```sh
test "$(usign -F -p /tmp/production-2026-07.pub)" = d055711acf1d9a5b
usign -q -V \
  -p /tmp/production-2026-07.pub \
  -m /tmp/SHA256SUMS \
  -x /tmp/SHA256SUMS.sig

for file in \
  premier-router-core_0.7.11~rc16-1_all.ipk \
  luci-app-premier-router_0.7.11~rc16-1_all.ipk \
  premier-router-setup_0.7.11~rc16-1_all.ipk \
  installed-manifest.json installed-manifest.json.sig \
  router-candidate-validator bootstrap-router-ui-ipk-install.sh
do
  expected="$(awk -v file="$file" '$2 == file {print $1}' /tmp/SHA256SUMS)"
  test -n "$expected"
  test "$(sha256sum "/tmp/$file" | awk '{print $1}')" = "$expected"
done
```

Every command must finish successfully. A missing hash, key-fingerprint
mismatch, or bad signature is a hard stop.

## 4. Install the upstream runtime prerequisites

Use only the OpenWrt feeds already configured for this exact router release
and target. `opkg` verifies their signed package indexes and selects the
target-specific package bytes. Install and verify the updater launcher and the
structural JSON runtime before any Router UI package transaction:

```sh
opkg update
opkg install coreutils-nohup ucode ucode-mod-fs
opkg status coreutils-nohup ucode ucode-mod-fs |
  sed -n '/^Package:/p;/^Version:/p;/^Architecture:/p;/^Status:/p'
command -v nohup
ucode -e 'import { readfile } from "fs"; print(type(readfile), "\n");'
df -h /overlay /tmp
```

The final two checks must print a `nohup` path and `function`. Stop if package
signature verification fails, a feed does not match OpenWrt 24.10.5, or the
remaining storage no longer meets the 0.7.11 preflight requirement. Do not use
`--force-depends`. These upstream packages intentionally remain installed if
the project packages roll back to RC5; retaining `coreutils-nohup` also repairs
RC5's worker-launch prerequisite.

## 5. Install and seed the signed rollback set

Run on the router:

```sh
chmod 700 /tmp/bootstrap-router-ui-ipk-install.sh
ROUTER_UI_ASSET_DIR=/tmp /tmp/bootstrap-router-ui-ipk-install.sh
sync
reboot
```

The bootstrap verifies the target and OpenWrt range, enforces persistent and
`/tmp` space reserves, verifies the signed installed-package manifest, creates
an OpenWrt configuration backup, and places a verified recovery seed on
persistent storage before asking `opkg` to change packages. It then installs
all three IPKs, validates the result, and preserves the exact IPK bytes as the
rollback source for a later signed update.

On an already configured OpenWrt router, the bootstrap seals the public
first-boot endpoint before making its recovery backup, and the setup package
independently locks that endpoint before its web files are installed. This
prevents the image-only setup wizard from reopening access to root, LAN, VPN,
or Tailscale configuration during an IPK installation. Offline image
construction skips the package guard so a newly flashed image can still
present its intended first-boot wizard.

The bootstrap refuses an already managed installation or any Router UI package
with a different version. If power loss or an `opkg` interruption leaves only a
subset of the exact RC16 packages, rerunning the same verified bootstrap and
asset set resumes the installation. For any other failure, stop and send the
preflight output for review; do not use `--force-depends`, `--force-overwrite`,
a blanket `opkg upgrade`, or manual file deletion.

## 6. Verify after the reboot

Reconnect by the router's LAN address and run:

```sh
opkg status premier-router-core luci-app-premier-router premier-router-setup |
  sed -n '/^Package:/p;/^Version:/p;/^Status:/p'
cat /usr/share/vpn-ui/version
cat /usr/share/premier-router/build-info
test -f /etc/firstboot-wizard/complete
test ! -L /etc/firstboot-wizard/complete
test "$(stat -c '%a' /etc/firstboot-wizard/complete)" = 600
QUERY_STRING='action=apply' CONTENT_LENGTH=0 /www/cgi-bin/firstboot-setup |
  grep -F 'Initial setup is already complete'
/usr/sbin/vpn-ui vpn-summary
/usr/sbin/vpn-ui tailscale-status
/usr/sbin/vpn-ui update-status
free -m
for service in xray-exit-st xray-transparent xray tailscale; do
  [ -x "/etc/init.d/$service" ] || continue
  /etc/init.d/$service enabled && enabled=yes || enabled=no
  /etc/init.d/$service running && running=yes || running=no
  echo "$service enabled=$enabled running=$running"
done
i=0
while [ "$i" -lt 15 ]; do
  date
  free -m | sed -n '1,2p'
  pidof xray tailscaled 2>/dev/null || true
  i=$((i + 1))
  sleep 2
done
dmesg | grep -Eai 'out of memory|oom-killer|killed process' || true
logread | grep -Eai 'out of memory|oom-killer|killed process' || true
logread | tail -n 160
dmesg | tail -n 100
```

Expected identity:

- all three package versions: `0.7.11~rc16-1`;
- displayed Router UI version: `0.7.11-rc.16`;
- release channel: `candidate` in build metadata and in Update-page status;
- both Xray and Tailscale remain healthy if they were configured before the
  installation;
- no out-of-memory kill, reboot loop, or loss of LAN management.

Open LuCI from the LAN. The Update page must report candidate `0.7.11-rc.16` and must
not offer a same-version update with different bytes.

If the router reboots unexpectedly or either daemon repeatedly dies, do not
repeat the installation. Keep it on LAN, capture `logread`, `dmesg`, `free -m`,
`df -h /overlay /tmp`, and the three `opkg status` results, then send those
redacted diagnostics with the router model and OpenWrt version. Do not include
VPN URLs, keys, passwords, or the backup archive.

## 7. Explicitly adopt a manual Xray configuration

If the ownership panel reports that Xray is using a manual configuration such
as `/etc/xray/config.json`, Router UI keeps profile changes and direct-rule
editing disabled. Do not press **Use** on a profile and do not try to work
around the disabled controls.

Complete the supervised reboot gate before adopting. Record the boot ID before
the reboot, reboot while a local recovery path is available, and verify both a
changed boot ID and final protocol state:

```sh
cat /proc/sys/kernel/random/boot_id
/usr/sbin/vpn-ui-update status
```

The state must be `committed`, not
`committed_pending_reboot_validation`. Adoption and every persistent VPN
configuration change are refused while reboot validation is pending. The
candidate validator may run a compatible read-only adoption preview, but it
does not create ownership metadata or rewrite Xray.

From the authenticated LuCI VPN page:

1. Select **Preview adoption**.
2. Confirm the sanitized active path, configuration SHA-256, rule-array counts,
   rule-array hashes, and compatibility warnings. No credentials or complete
   configuration are displayed.
3. Record the current configuration hash independently on the router:

   ```sh
   sha256sum /etc/xray/config.json
   ```

4. Select **Adopt without rewrite** and then run the same `sha256sum` command.
   The hash must be identical. Adoption must not restart Xray.
5. Confirm the ownership panel says **Adopted overlay** and shows the expected
   domain/IP counts.

An ambiguous layout, multiple discovered configuration paths, a symlinked or
drifted path, an unsupported multi-config invocation, or insufficient storage
is a hard stop. Do not delete the ownership journal or edit its hashes to force
adoption.

After successful adoption, the complete panel is enabled only while the
adopted overlay is healthy: global VPN, profile add/use/delete, subscription
import/sync/delete, ping refresh, automatic switching, direct-rule Apply, and
device VPN. Each mutation must preserve the adopted layout outside the
explicitly managed fields and retain the admin and Tailscale route invariants.

The panel fails closed when adoption is required, ownership or configuration
has drifted, recovery is active, reboot validation is pending, or the current
session is read-only. A read-only adoption preview or route diagnostic does
not unlock persistent controls. On any validation, restart, or invariant
failure, leave Xray stopped if instructed and retain the private transaction
under `/etc/premier-router/xray-transactions` for recovery.
