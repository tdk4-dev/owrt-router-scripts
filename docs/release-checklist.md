# Router UI 0.7.11 release checklist

- Confirm the exact annotated `vpn-panel-v0.7.11` tag already exists, points at
  a clean 0.7.11 commit, and is contained in `origin/main`.
- Configure protected environments `router-ui-production-signing` and
  `router-ui-production-release`, production usign public/private secrets, and
  `ROUTER_UI_RELEASE_KEY_ID`. Never print the secret key.
- Dispatch `Prepare verified Router UI release` for the exact tag with
  `publish=false`. It builds canonical IPKs once, compares a reproducibility
  build, builds all images from the canonical artifact, signs, strictly
  validates, creates a draft, downloads every asset, and compares exact bytes.
- Review retained logs, the flat asset count, signatures, hashes, package and
  image provenance, VM matrix, failure injection, and authorized canary proof.
- Dispatch the exact tag with `publish=true` only after the required explicit
  publication authorization. The publisher refuses missing/lightweight tags,
  dirty source, non-main ancestry, mismatched assets, or a non-draft release.
- Download the public assets into an empty directory and repeat strict
  verification. Keep 0.7.11 latest until all known legacy routers migrate.
- Post the prepared issue #10 comment only after public verification and the
  authorized friend's x86 canary remains healthy after reboot.

No tag push triggers publication. The workflow never creates a tag and never
uses `--clobber`.
