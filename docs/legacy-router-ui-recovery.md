# Legacy Router UI recovery through 0.7.11

This guide is prepared for publication after 0.7.11 assets are public and
verified. The immutable implementation source is commit
`0c792b60494c21907f042e70c00a6a9189f0516e`; the staged rescue script SHA-256
is `037e9cec09e32f5b825ee7bd9c711044433761a6c3dbaad8d344eec358301938`.

Supported source versions are 0.5.1, 0.5.2, 0.6.0, 0.7.0–0.7.6, 0.7.8,
0.7.9, and 0.7.10. Version 0.7.7 is tag-only without a published artifact.
Unknown, development, and RC versions fail closed. The historical immutable
0.7.1-only rescue remains historical; this generic rescue installs 0.7.11
first, after which the normal Update page can install a later signed stable
package release.

Prepared direct-router flow:

```sh
cd /tmp
curl -fL --proto '=https' \
  https://github.com/tdk4-dev/owrt-router-scripts/releases/download/vpn-panel-v0.7.11/rescue-router-ui.sh \
  -o rescue-router-ui.sh
echo '037e9cec09e32f5b825ee7bd9c711044433761a6c3dbaad8d344eec358301938  rescue-router-ui.sh' | sha256sum -c -
sh rescue-router-ui.sh
```

If the router cannot download, verify the hash on the admin computer and stream
the bytes over SSH: `ssh root@ROUTER 'cat > /tmp/rescue-router-ui.sh' <
rescue-router-ui.sh`. `scp -O` is only an optional workaround for legacy SCP.
Never post configs, URLs, UUIDs, keys, or backups to issue #10.

Expected success ends with “Router UI 0.7.11 is installed with updater protocol
v2” and prints the exact rollback path. Use the verification and rollback
commands in `router-ui-0.7.11-transition.md`. Do not run global `opkg upgrade`
and do not flash firmware.

Physical validation is pending until the explicitly authorized friend's x86
router succeeds and remains healthy after reboot; issue #10 must remain open
until then.

## Prepared issue #10 comment

The generic recovery is available at immutable commit
`0c792b60494c21907f042e70c00a6a9189f0516e` and as the exact 0.7.11 release
asset. Its SHA-256 is
`037e9cec09e32f5b825ee7bd9c711044433761a6c3dbaad8d344eec358301938`.
It accepts only the versions
listed above and installs 0.7.11 first. Follow the verified download, hash,
execution, verification, and rollback commands in this guide. The old 0.7.1
rescue is retained for history. Physical friend's-router validation is still
pending, so this issue should remain open.
