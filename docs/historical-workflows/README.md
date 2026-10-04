# Historical Router UI workflow contracts

The two YAML files in this directory are byte-for-byte copies of the old
canonical definitions at PR #28 source
`9d313dca35d8478fef56e3dbfd376838bf54946c`:

- `validate-router-ui-candidate-rc15.yml` formerly occupied
  `.github/workflows/validate-router-ui-candidate.yml`.
- `release-vpn-panel-rc15.yml` formerly occupied
  `.github/workflows/release-vpn-panel.yml`.

They require historical RC15 identities, image artifacts, and historical VM
evidence. They are retained as audit material outside the active workflow
directory, not as execution instructions for current package-only candidates.
Their old release/publication actions are not authorized by preservation here.

Current paths and scope:

| Entry point | Current role |
|---|---|
| `ci.yml`, `router-ui-source-preflight.yml` | Exact-source, build-free checks |
| `validate-router-ui-candidate.yml` | Explicit RC19 or future stable package tuple; custody-gated private package preparation; no publication |
| `release-vpn-panel.yml` | Read-only verification of an exact retained package artifact; no rebuild, signing, tag or release |
| `publish-router-ui-rc8-virtualbox-evidence.yml` | Historical RC8 evidence contract only |
| `publish-router-ui-rc15-virtualbox-evidence.yml` | Historical RC15 evidence contract only |
| `diagnose-router-ui-vm.yml` | Historical RC15/synthetic-successor diagnostic artifact path; no current stable qualification claim |
| `build-router-ui-legacy-baselines.yml` | Independent published-baseline fixture builder; not current candidate qualification |
| `scripts/create-local-rc-bundle.sh` | Historical image-inclusive archive format; rejects RC19 and stable before output mutation |
| `publish-vpn-panel-release.sh` | Separately authorized manual publisher; current package-only artifact verification and `--latest=false` remain enforced |

RC-specific validators and diagnostic helpers retain their historical
identities. Do not relabel their results or feed current prepared package
artifacts into them as a substitute for the complete authenticated control
census and signed-byte VM matrix in the current release checklist.
