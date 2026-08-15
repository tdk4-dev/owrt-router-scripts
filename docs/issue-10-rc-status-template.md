## Router UI 0.7.11 RC11 Phase 1 status

Router UI `0.7.11-rc.11` (`0.7.11~rc11-1`, candidate channel) has reached the
Phase 1 status recorded below. This template must not claim canonical package,
image, signing, hardware, or release qualification. Issue #10 remains open.

- Exact source commit: `@PHASE1_SOURCE_COMMIT@`
- Exact source tree: `@PHASE1_SOURCE_TREE@`
- Draft PR: `@DRAFT_PR_URL@`
- Exact-SHA preflight run: `@PREFLIGHT_RUN_URL@`
- Preflight source/result: `@PREFLIGHT_SOURCE_SHA@ / @PREFLIGHT_RESULT@`
- Provisional package set: `@PROVISIONAL_PACKAGE_HASHES@`
- Disposable VM/boot identity: `@VM_AND_BOOT_IDENTITY@`
- Direct-localhost browser evidence: `@BROWSER_EVIDENCE@`
- Fixture restoration proof: `@RESTORATION_EVIDENCE@`
- Physical routers touched: none

The complete adopted panel is enabled only for a healthy adopted overlay. It
fails closed in adoption-required, drift/recovery, reboot-pending, and
read-only states. Phase 1 must cover Update, VPN, and Tailscale controls through
the machine-readable census and the real LuCI → RPC/ACL → backend path.

Phase 1 evidence is provisional. It is not an A/B reproducibility build, a
canonical signed artifact set, an image build, a full VM matrix, a hardware
canary, a tag, a release, distribution authorization, or rollout readiness.

Remaining blockers are recorded at `@REMAINING_BLOCKERS@`. No merge, tag,
GitHub release, production signing, image build, Factory work, router contact,
distribution, or rollout was authorized by this status update.
