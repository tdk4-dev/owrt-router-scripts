# Router UI 0.7.11 historical rescue support

This matrix is limited to actual Router UI 0.7.x publication identities that
can be reconstructed from the immutable baseline lock in
`tests/vm/legacy-baseline-lock.json`. Each rendered rescue asset is pinned to
the exact application and package versions in its signed manifest. Every
supported source converges on that manifest's same three canonical IPK bytes.

| Source | Publication evidence | Support | Compatibility path |
| --- | --- | --- | --- |
| 0.7.0 | Published immutable asset | Supported directly | None |
| 0.7.1 | Published immutable asset | Supported directly | None |
| 0.7.2 | Published immutable asset | Supported directly | None |
| 0.7.3 | Published immutable asset | Supported directly | None |
| 0.7.4 | Published immutable asset | Supported directly | None |
| 0.7.5 | Published immutable asset | Supported directly | None |
| 0.7.6 | Published immutable asset | Supported directly | None |
| 0.7.7 | Tag only; no immutable published install asset | Unsupported | Refused before download or modification |
| 0.7.8 | Published immutable asset | Supported directly | None |
| 0.7.9 | Published immutable asset | Supported through one deterministic adapter | Install the verified no-op `_35_vpn.js` status include during the transition only |
| 0.7.10 | Published immutable asset | Supported directly | None |

The rescue refuses pre-0.7, unknown, malformed, development, RC, 0.7.7 and
newer sources. It verifies the embedded public-key fingerprint, the signed
candidate manifest and every downloaded asset before invoking the protocol-v2
transaction supervisor. The supervisor creates an OpenWrt configuration
backup and exact application rollback material before mutation, installs only
the three manifest-pinned IPKs with `opkg install`, preserves protected
configuration, validates the target and prints the exact rollback command. It
never flashes firmware and never runs a global `opkg upgrade`.
