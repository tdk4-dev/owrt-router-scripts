## Router UI 0.7.11 local RC status

Router UI 0.7.11 RC6 has completed local Mac Pro validation. This is not yet
the stable production installation instruction. The existing 0.7.1 to 0.7.10
instructions remain historical, and issue #10 must remain open.

- RC source: `@RC_SOURCE_COMMIT@`
- RC archive SHA-256: `@RC_ARCHIVE_SHA256@`
- Active signing key: `production-2026-07` (`d055711acf1d9a5b`)
- Canonical IPKs: `@CANONICAL_IPK_HASHES@`
- Historical sources tested: 0.7.0, 0.7.1, 0.7.2, 0.7.3, 0.7.4, 0.7.5,
  0.7.6, 0.7.8, 0.7.9 and 0.7.10
- Rescue matrix: `@RESCUE_MATRIX_RESULT@`
- Vanilla OpenWrt 24.10.5: direct verified IPKs and signed candidate feed both
  passed without a firmware flash or global package upgrade
- Stable-promotion proof: signed `0.7.11-rc.6` to stable `0.7.11`, exact
  rollback to `0.7.11-rc.6`, repeat update, and second exact rollback passed
- Physical routers touched: none

Remaining stable-publication blockers:

1. one controlled physical hardware canary;
2. at least two encrypted private-key backups, including one off the Mac Pro,
   with a successful fingerprint recovery test;
3. explicit stable-publication authorization.

No stable release or tag was created by this validation task.
