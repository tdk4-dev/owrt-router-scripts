## Router UI 0.7.11 release-readiness status

Router UI `0.7.11` (`0.7.11-1`, stable channel) is the identity-only promotion
of qualified RC16. This template must not claim publication, hardware, or
rollout authorization beyond attached evidence. Issue #10 remains open.

- Exact source commit: `@PHASE1_SOURCE_COMMIT@`
- Exact source tree: `@PHASE1_SOURCE_TREE@`
- Draft PR: `@DRAFT_PR_URL@`
- Exact-SHA preflight run: `@PREFLIGHT_RUN_URL@`
- Preflight source/result: `@PREFLIGHT_SOURCE_SHA@ / @PREFLIGHT_RESULT@`
- Canonical package set: `@PROVISIONAL_PACKAGE_HASHES@`
- Disposable VM/boot identity: `@VM_AND_BOOT_IDENTITY@`
- Direct-localhost browser evidence: `@BROWSER_EVIDENCE@`
- Fixture restoration proof: `@RESTORATION_EVIDENCE@`
- Physical routers touched: none

The complete adopted panel is enabled only for a healthy adopted overlay. It
fails closed in adoption-required, drift/recovery, reboot-pending, and
read-only states. Phase 1 must cover Update, VPN, and Tailscale controls through
the machine-readable census and the real LuCI → RPC/ACL → backend path.

The attached evidence must include stable reproducibility and exact-byte VM
smoke. It is not an image build, hardware canary, tag, GitHub Release,
distribution authorization, or rollout authorization.

Remaining blockers are recorded at `@REMAINING_BLOCKERS@`. No merge, tag,
GitHub Release, image build, Factory work, router contact, distribution, or
rollout is authorized by this status update.
