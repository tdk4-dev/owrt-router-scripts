# VM Release Testing Methodology

Use this method before publishing router UI releases and before merging high
risk changes that affect setup, update, packaging, reset, VPN, Tailscale, or
authentication.

## Test Inputs

Record:

- source commit;
- `APP_VERSION`;
- `OPENWRT_VERSION`;
- package filenames and SHA-256 hashes;
- image archive filename and SHA-256 hash;
- VM name and host;
- network mode and expected test URL.

## VM Resource Limit

- Configure every mandatory OpenWrt release-test VM with exactly 256 MiB RAM.
- Run one project VM at a time by default and never more than two at once. The
  process/semaphore guard must refuse a third VM.
- Record configured RAM and `/proc/meminfo` `MemTotal` for every VM start.
- Treat any request for 300 MiB or more, or any third simultaneous VM, as a
  failed release gate.

The mandatory stock profile uses an x86 squashfs image whose writable overlay
is hard-capped at 61,440 KiB. Record and assert `df -Pk /`, `/overlay`, and
`/tmp`; `/tmp` must remain RAM-backed. A larger disk with merely 60 MiB free is
not storage-constrained. Repeat supplemental transition and rollback checks at
75 MiB and 85 MiB, but never substitute those results for the 60 MiB gate.

## Clean Image Test

1. Create or reset a VirtualBox VM from the exact x86 image archive under test.
2. Boot the VM.
3. Verify the setup wizard is reachable at the expected URL.
4. Complete setup end to end:
   - root password;
   - Wi-Fi screen behavior when radios are absent;
   - direct VLESS link import;
   - HTTPS subscription link import;
   - AdGuard filter choice;
   - Tailscale/Headscale registration from the setup wizard.
5. Verify LuCI login with the configured password.
6. Verify LuCI pages:
   - Status overview;
   - `Network > VPN Panel`;
   - `Network > Tailscale`;
   - `System > Update`;
   - `System > Reset`.
7. Verify reset returns the router to setup state and removes customer setup
   state while preserving only expected image defaults.

## IPK Tests

On a compatible OpenWrt VM:

- clean install IPKs using `opkg`;
- verify `opkg status` and `opkg files`;
- verify LuCI app availability and backend services;
- repeat install to check idempotency;
- upgrade from an older package-managed version;
- migrate from a real legacy tar.gz-managed install;
- verify conffiles and runtime state are preserved.

## Failure Tests

Simulate:

- corrupt checksum;
- missing asset;
- missing package;
- wrong architecture;
- health-check failure;
- network timeout during update.

Expected behavior:

- installation stops;
- no silent fallback;
- backup path is printed;
- opkg/file state remains explainable;
- recovery command is valid.

For protocol v2, inject interruption before mutation, after each IPK, during
target validation and commit, at rollback start, after each rollback IPK, and
during final cleanup. Reboot after every mutating interruption and run
`/etc/init.d/premier-router-update-recovery start`. Accept only a committed,
target-validated state or an exact, source-validated rollback. Preserve the
journal, validator JSON, package status, config hashes, service state, and boot
ID as evidence.

## 0.7.11 transition matrix

Create disposable x86 baselines from the exact downloaded release artifacts
for 0.7.1, 0.7.9, 0.7.10, and every other source marked supported in
`router-ui-update-transition-matrix.md`. For 0.7.9 and 0.7.10, leave the exact
old updater process in memory while it installs the staged bridge. Confirm its
own final predicate returns success and no rollback executes. Run generic
rescue for the other baselines. Then test 0.7.11 to a synthetic signed protocol
v2 target, exact manual rollback, and boot recovery.

Serve the flat staged directory under both `releases/latest/download` and
`releases/download/vpn-panel-v0.7.11`. Record the source and target versions,
transaction ID, status-card count, LuCI route load, protected config hashes,
package versions, installed manifest hash, recovery archive validation, and
rollback bundle validation before and after reboot.

Boot the x86 image with exactly 256 MiB RAM and a writable overlay no larger
than 61,440 KiB. Extract both RD23 variants and prove
their embedded canonical IPK hashes. Do not label RD23 hardware verified until
an explicitly authorized physical device test has occurred.

## Tailscale / Headscale GUI Coverage

Test both GUI paths:

- first-boot setup wizard registration;
- LuCI Tailscale panel registration after setup skipped Tailscale.

Do not count terminal-only enrollment as GUI verification.

## Evidence Format

Save concise command output or screenshots for each pass/fail. Mark evidence
using only labels that were actually verified:

- `source-verified`
- `package-build-verified`
- `OpenWrt-runtime-verified`
- `VM-verified`
- `hardware-verified`
