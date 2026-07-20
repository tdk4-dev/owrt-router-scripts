# Router UI 0.7.11 release checklist

- Configure protected environments `router-ui-production-signing` and
  `router-ui-production-release`. Store only `ROUTER_UI_USIGN_SECRET_KEY` in
  the signing environment; the committed public key, fingerprint, and key ID
  are authoritative. Never print the secret key.
- Dispatch `Validate production-signed Router UI candidate` with the exact
  release commit SHA. It creates no tag or release. Require byte-reproducible
  canonical IPKs, all three images, strict signatures, and the complete serial
  256 MiB/exact-RD23-storage VM evidence artifact.
- Merge the tested release commits into the forward branch with a real merge,
  merge PR #12 with a merge commit, and verify the exact release commit is an
  ancestor of `origin/main` while main retains its intended 0.8 version.
- Create and verify one signed annotated `vpn-panel-v0.7.11` tag pointing to
  the exact candidate source commit, then push it once. Never move or recreate
  the tag.
- Dispatch `Prepare verified Router UI release` for the exact tag with
  `publish=false`. It rebuilds canonical IPKs twice, builds all images from the
  retained first artifact, compares every assembled byte with the successful
  pre-tag candidate, reruns the complete VM gate, creates a draft, downloads
  every asset, and compares exact bytes.
- Review retained logs, the flat asset count, signatures, hashes, package and
  image provenance, VM matrix, failure injection, and authorized canary proof.
- Dispatch the exact tag with `publish=true` only after the required explicit
  publication authorization. The publisher refuses missing/lightweight tags,
  dirty source, non-main ancestry, mismatched assets, or a non-draft release.
- Download the public assets into an empty directory and repeat strict
  verification. Keep 0.7.11 latest until all known legacy routers migrate.
- Post the prepared issue #10 comment only after public verification. Keep the
  issue open because the separately authorized friend's physical x86 test is
  still pending.

No tag push triggers publication. The workflow never creates a tag and never
uses `--clobber`.
