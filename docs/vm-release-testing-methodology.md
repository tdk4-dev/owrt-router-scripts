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
