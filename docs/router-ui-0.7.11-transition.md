# Router UI 0.7.11 transition release

0.7.11 is a minimal bridge based on the immutable 0.7.10 product commit. It
adds package ownership, updater protocol v2, signed metadata, exact rollback,
boot recovery, source-specific 0.7.9/0.7.10 handoff, and generic legacy rescue.
It intentionally contains no 0.8 product panels, reset work, branding change,
or feature expansion.

The supported in-panel path is exactly 0.7.9 or 0.7.10 to 0.7.11. Other
recognized published baselines use `rescue-router-ui.sh`; rescue always pins
0.7.11 and never jumps to a future latest release. 0.7.7, unknown versions,
development builds, and RC builds are refused.

After installation, verify:

```sh
cat /usr/share/vpn-ui/version
grep '^UPDATER_PROTOCOL=2$' /usr/share/premier-router/build-info
opkg status premier-router-core luci-app-premier-router premier-router-setup
/usr/sbin/vpn-ui-update status
transaction="$(cat /root/premier-router-updates/active-transaction)"
cat "/root/premier-router-updates/$transaction/state.json"
tar -tzf "/root/premier-router-updates/$transaction/openwrt-configuration-recovery.tar.gz" >/dev/null
```

Manual exact rollback is:

```sh
transaction="$(cat /root/premier-router-updates/active-transaction)"
sh "/root/premier-router-updates/$transaction/rollback.sh"
```

Do not run a global `opkg upgrade` and do not flash firmware as part of this
application transition.
