# Install Router UI on vanilla OpenWrt 24.10.5

These are the two candidate installation paths exercised on a clean official
OpenWrt 24.10.5 x86/64 VirtualBox guest. They install ordinary IPKs. They do
not flash firmware and they never run `opkg upgrade`.

## A. Direct verified IPKs

From the administrator's workstation, stream the public verification inputs
and exact IPKs to the router. This works with Dropbear even when SFTP is not
installed:

```sh
for file in \
  production-2026-07.pub SHA256SUMS SHA256SUMS.sig \
  premier-router-core_0.7.11-1_all.ipk \
  luci-app-premier-router_0.7.11-1_all.ipk \
  premier-router-setup_0.7.11-1_all.ipk
do
  ssh root@ROUTER_ADDRESS "umask 077; cat > '/tmp/$file'" < "./$file"
done
```

Then run on the router:

```sh
test "$(usign -F -p /tmp/production-2026-07.pub)" = d055711acf1d9a5b
usign -q -V \
  -p /tmp/production-2026-07.pub \
  -m /tmp/SHA256SUMS \
  -x /tmp/SHA256SUMS.sig

for file in \
  premier-router-core_0.7.11-1_all.ipk \
  luci-app-premier-router_0.7.11-1_all.ipk \
  premier-router-setup_0.7.11-1_all.ipk
do
  expected="$(awk -v file="$file" '$2 == file {print $1}' /tmp/SHA256SUMS)"
  test "$(sha256sum "/tmp/$file" | awk '{print $1}')" = "$expected"
done

opkg update
opkg install \
  /tmp/premier-router-core_0.7.11-1_all.ipk \
  /tmp/luci-app-premier-router_0.7.11-1_all.ipk \
  /tmp/premier-router-setup_0.7.11-1_all.ipk
reboot
```

## B. Signed candidate feed

Install the reviewed public feed key by streaming it from the administrator's
workstation:

```sh
ssh root@ROUTER_ADDRESS \
  'umask 077; cat > /etc/opkg/keys/d055711acf1d9a5b' \
  < ./production-2026-07.pub
```

On the router, add the reviewed candidate feed URL and install the user-facing
package set. `CANDIDATE_FEED_URL` must refer to the extracted, TLS-served
contents of `premier-router-opkg-feed-0.7.11.tar.gz`:

```sh
printf '%s\n' \
  'src/gz premier_router CANDIDATE_FEED_URL' \
  > /etc/opkg/customfeeds.conf.d/premier-router.conf
opkg update
opkg install \
  premier-router-core \
  luci-app-premier-router \
  premier-router-setup
reboot
```

After either path, confirm the exact result:

```sh
opkg status premier-router-core luci-app-premier-router premier-router-setup
/usr/sbin/vpn-ui check
/usr/sbin/vpn-ui vpn-summary
/usr/sbin/vpn-ui tailscale-status
/usr/sbin/vpn-ui update-status
```

The three package versions must be `0.7.11-1`. The VPN and Tailscale status
commands validate configuration handling without requiring real enrollment or
real VPN credentials.
