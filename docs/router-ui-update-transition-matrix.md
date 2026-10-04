# Router UI transition matrix

The machine-readable authority for this audit is
`release/transition-matrix.json`. It was built from fetched Git tags, GitHub
release metadata, downloaded release assets, and the exact updater, bundle
installer, and standalone installer stored at each tag.

| Source | Published artifact | Normal Update page to 0.7.11 | Direct rescue to 0.7.11 | Important source contract |
|---|---:|---|---|---|
| 0.5.1, 0.5.2, 0.6.0 | yes | not claimed | implemented; VM pending | legacy tar transport; unequal strings meant “available” |
| 0.7.0–0.7.6 | yes | not claimed | implemented; VM pending | tar plus standalone; numeric-component comparison |
| 0.7.7 | no (tag only) | refused | refused | no published installation artifact to reproduce |
| 0.7.8 | yes | not claimed | implemented; VM pending | tar plus standalone |
| 0.7.9 | yes | host tested; VM pending | implemented; VM pending | the live old worker requires both `35_vpn.js` and `_35_vpn.js` |
| 0.7.10 | yes | host tested; VM pending | implemented; VM pending | the live old worker requires `35_vpn.js` and forbids `_35_vpn.js` |
| unknown, development, RC | n/a | refused | refused | fail closed |

“Implemented” is not a physical-validation claim. The rescue source parser and
host transaction are tested, but every published baseline still requires the
disposable-VM run described in `vm-release-testing-methodology.md` before the
release can be published.

The 0.7.9 bridge installs a signed no-op `_35_vpn.js`. Its `render()` returns
`null`, so it satisfies the immutable old worker without creating a second
visible card. Boot recovery removes it after the old process can no longer be
running. The 0.7.10 bridge keeps the file absent.

Legacy 0.7.x workers own the outer transaction result: on bridge failure they
invoke the marker written before mutation. Protocol v2 owns rollback after it
is installed. There is never an installer rollback followed by a second,
competing worker rollback.
