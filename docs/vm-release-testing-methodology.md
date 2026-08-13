# VM Release Testing Methodology

Use this method before publishing router UI releases and before merging high
risk changes that affect setup, update, packaging, reset, VPN, Tailscale, or
authentication.

## Phase 1 provisional three-IPK checkpoint

Phase 1 is a single, non-production functional checkpoint before canonical
qualification. It uses at most one three-IPK byte set from an exact clean
source SHA. It is not an A/B reproducibility build, a signed candidate,
distribution collateral, an image build, or release evidence.

- Commit and push the intended source, open a draft PR, and wait for the
  reusable exact-SHA source preflight to pass before producing packages.
- Use no production key or protected signing environment. If the disposable
  path requires signatures, use an explicitly non-production test identity.
- Record the exact source commit/tree, input locks, filenames, sizes, and
  SHA-256 hashes before VM installation. Never change tracked source after the
  checkpoint begins.
- Create or prove a uniquely named disposable clone/snapshot. Never mutate,
  reuse, unregister, delete, sanitize, or replace a historical, operational,
  or sensitive evidence VM.
- Record host, VM UUID/name, snapshot/clone parent, boot ID, configured RAM,
  package hashes, and pre-install configuration/service/route hashes.
- Install the unchanged bytes and exercise every applicable machine-readable
  census entry through real LuCI → RPC/ACL → backend behavior.
- Run the browser on the same workstation that hosts the VM and use a direct
  localhost port. An SSH tunnel, VPN path, LAN address, remote browser, or
  remote automation result is not same-workstation browser proof.
- Retain screenshots or DOM evidence, backend/RPC results, zero browser-console
  errors, admin and Tailscale route invariants, and exact post-test restoration
  hashes.
- The complete adopted panel is enabled only for a healthy adopted overlay and
  fails closed in adoption-required, drift/recovery, reboot-pending, and
  read-only states.

If the checkpoint finds a source or packaged-file defect, mark its evidence
invalid, restore the disposable VM, and stop. Do not build replacement bytes in
the same Phase 1 run and do not nominate a freeze. Canonical package, image,
signing, full-matrix, hardware, Factory, tag, release, distribution, and rollout
gates remain skipped.

## Test Inputs

Record:

- source commit;
- `APP_VERSION`;
- `OPENWRT_VERSION`;
- package filenames and SHA-256 hashes;
- image archive filename and SHA-256 hash;
- VM name and host;
- network mode and expected test URL.

The remaining sections define later canonical/release qualification unless a
section explicitly says it applies to the Phase 1 provisional checkpoint.

## Diagnostic QEMU boundary

- QEMU is diagnostic-only for RC7 and cannot authorize candidate or release
  publication. The mandatory qualification hypervisor is VirtualBox on the Mac
  Pro, using a disposable, locally recoverable clone under supervision.
- Configure every diagnostic OpenWrt QEMU VM with exactly 256 MiB RAM.
- Run every project VM case strictly serially, with exactly one project VM at
  a time and workflow/matrix parallelism fixed at 1.
- Track only the exact QEMU PID started by the current case. Terminate and wait
  for that PID before starting the next case, including on failure or
  cancellation. Never scan or kill unrelated host QEMU processes.
- Boot the disposable x86 baseline with an IDE disk and e1000 NIC, matching
  drivers present in the exact generated image, and retain its serial console
  log with the case evidence.
- Never inject commands into a guest during its preinit/failsafe window. The
  clean release image may receive its disposable test key and CA only after
  the serial console-ready marker, using paced UART input.
- Record configured RAM and `/proc/meminfo` `MemTotal` for every VM start.
- Treat any request for 300 MiB or more, or any overlapping diagnostic project
  VM case, as a failed diagnostic run.

The Mac Pro qualification evidence must bind the exact source SHA and signed
release-manifest hash, prove fingerprint `d055711acf1d9a5b`, record a changed
boot ID, and cover RC5 → RC7 candidate preview, post-reboot commit, adoption,
LuCI/RPC direct-rule apply and removal, Xray restart, exact rollback, and
continuous Tailscale invariants. Same-workstation browser proof must use direct
localhost access. `validate-rc7-virtualbox-evidence.sh` enforces this contract.

## Pre-merge VirtualBox evidence publication

GitHub can dispatch a manual workflow only after that workflow path exists on
the default branch. Expose the evidence publisher with a separate bootstrap PR
from `origin/main` containing exactly
`.github/workflows/publish-router-ui-rc7-virtualbox-evidence.yml`. Do not merge
the RC merely to expose its qualification workflow.

Run the publisher on `main`, with the candidate commit supplied only as the
`source_sha` data input. The publisher must not check out or execute candidate
code. Its artifact is accepted by the candidate workflow only when GitHub
metadata proves that it came from the exact manually dispatched publisher path
on `main` at the operator-supplied publisher commit. The bundle is then checked
again against the newly built and production-signed candidate.

The Mac Pro host currently runs macOS 10.14 and therefore cannot run a current
supported GitHub runner; GitHub currently supports self-hosted macOS runners on
macOS 11 or later. Use a disposable Ubuntu 20.04-or-later x86_64 VM on the Mac
Pro as a repository-scoped, one-job ephemeral publisher. A fresh dedicated VM
is preferred over `u-vpn-exit`; the latter contains operational networking state
and should be used only after an explicit risk decision.

The publisher VM requires:

- the default `self-hosted`, `linux`, and `x64` labels plus the unique
  `mac-pro-evidence-publisher` label;
- `jq`, GNU `coreutils` (`sha256sum`), `findutils`, `gawk`, `grep`, `sed`,
  `sort`, `cmp`, Python 3, and CA certificates;
- outbound HTTPS to GitHub Actions endpoints;
- no repository checkout, production signing key, router credentials,
  VirtualBox control socket, or write access to the evidence source;
- a root-owned, read-only staged tree at
  `/srv/router-ui-evidence/rc7-final/<source-sha>` and the matching signed
  release at
  `/srv/router-ui-evidence/releases/<source-sha>/release-v0.7.11-rc.7`;
- protected environment approval for
  `router-ui-mac-pro-virtualbox-evidence`; and
- external retention of the ephemeral runner diagnostic logs.

Before approval, compute and retain the Mac Pro SHA-256 of
`evidence-files-sha256sums`. Supply that 64-hex value as the publisher's
`evidence_index_sha256` input. The publisher rejects writable, linked,
unexpected, oversized, or secret-shaped evidence and compares the retained
index before upload. The protected candidate separately binds the resulting
artifact ID, ZIP SHA-256, publisher commit and signed candidate manifest.

Register it with a repository runner token using `--ephemeral --unattended`
and `--labels mac-pro-evidence-publisher`, start it only after the protected
publisher job is queued and approved, and destroy its work directory or the
entire disposable VM after the one job deregisters. Never reuse the runner for
pull-request or candidate-controlled jobs.

Storage profiles are derived from the official OpenWrt 24.10.5 RD23 DTS,
kernel UBI configuration, and the exact candidate payload. The stock DTS has a
78 MiB raw UBI partition and the ubootmod DTS has a 112 MiB raw UBI partition.
After UBI reserves and the exact 0.7.11 rootfs/FIT payload, the current derived
`rootfs_data` extents are 54,436 KiB (stock) and 80,352 KiB (ubootmod). The
ubootmod derivation retains its two 1 MiB U-Boot environment volumes. Their
expected UBIFS `df -Pk` totals are 51,352 KiB and 76,728 KiB respectively.

The x86 VM filesystem differs from UBIFS, so the harness does not confuse an
ext4 `df` total with NAND capacity. It patches the disposable ImageBuilder to
make the rootfs-data backing extent exactly equal to the derived RD23
`rootfs_data` bytes, asserts that backing-device size in the guest, and records
`df -Pk /`, `/overlay`, and `/tmp`. `/tmp` must remain RAM-backed. A larger
filesystem with only its free space filled down is not storage-constrained.
The signed image provenance retains the source geometry, exact candidate
payload size, derived UBI accounting, and expected target UBIFS total.

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

Boot the x86 image with exactly 256 MiB RAM and a writable backing extent equal
to the value derived from the exact RD23 stock candidate. Extract both RD23
variants and prove their embedded canonical IPK hashes and storage provenance.
Do not label RD23 hardware verified until an explicitly authorized physical
device test has occurred.

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
