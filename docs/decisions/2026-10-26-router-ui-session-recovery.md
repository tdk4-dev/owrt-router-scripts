# Update observation after RPC session loss

Status: focused source and provisional native-browser checkpoint PASS; candidate identity/freeze/build/signing and exact-byte hardware acceptance pending.
Base: fetched origin/main18562f49 plus ordinary RC24 lineage merge, isolated branch codex/router-ui-rc25-session-recovery. RC24 bytes remain immutable.

Changed surface: LuCI System > Update job observer and restored-page rendering. Risk: high (updater result/authentication integration); no ACL/authentication or package transaction semantics are relaxed.

Hardware reproducer: signed RC22 -> RC24 on owner spare OpenWrt24.10.8. Native apply, reboot commit, exact rollback/reboot and29 protected hashes passed. rpcd restart expired the browser session; the UI eventually hid LuCI's Log in modal and reported Update failed safely despite native success. Safe hardware evidence is retained outside Git in output/reviews/router-ui-rc24-transition-20261025/HARDWARE_CANARY.md; canonical incident INC-2026-10-26-02.

Acceptance: SessionError ends observation immediately and preserves LuCI's login dialog; an unknown observation result is never asserted to be a failed transaction. An authoritative failed exact job remains a failure. A fresh authenticated page must persistently display pending reboot and block another Apply until validation completes. Existing operation-ID/kind correlation and read-only ACL controls remain enforced.

Cheapest disprovers: mocked actual view with a LuCI SessionError after an accepted Apply, a transport interruption, a failed exact job, and a fresh pending-reboot native status. Retain red results on unchanged RC24. Then run relevant rendering/control/security tests and a single provisional disposable-VM real-browser checkpoint before freeze or double build/signing.

Legacy limitation: a new package cannot replace JavaScript already loaded by an RC22 browser tab. That first bridge hop may still show the legacy session-expiry behavior; its standard Log in path must recover onto the new page with truthful pending-reboot status. Do not claim seamless old-page session retention. Newly loaded fixed views must preserve the login action and avoid false safe-failure claims.

Invalidated evidence: RC24 source/package/VM/hardware acceptance cannot qualify changed UI bytes or a new candidate. Unchanged fixture/dependency caches and original RC24 reproducer evidence may be reused only as inputs/baselines. No production signing/publication/integration has been requested for this fix.

Primary LuCI contract: https://github.com/openwrt/luci/blob/openwrt-24.10/modules/luci-base/htdocs/luci-static/resources/luci.js — notifySessionExpiry displays the login modal then raises SessionError. The fix must preserve that authentication boundary.

## Focused checkpoint evidence

Source/UI fix commit: `f197375b9f6e098654ba517e33c7f0ab72941296`; tree `05dc5638db481b0119323fc987fb74651ff2cb28`. The unchanged RC24 view reproduced302 calls (start plus301 expired polls); the regression requires start plus one expired poll. Focused operation/render/control/ACL/security checks and exact-SHA zero-build Tier0 passed46/46. Linux source CI40245648927 passed.

One unique test-only IPK, `premier-router-ui-session-probe` version `0.0.0+f197375b9f6e-1`, serves the exact changed view bytes at a disposable-only LuCI route using the existing native ACL/helper. View SHA256 `beb383f4e856439e2f9a6cf66834368e9be5979fdad25799d5855295115c39ef`; probe IPK SHA256 `c27249f782d32ee337bd39ce01fc5bd835a199058a60c25ffbd67f0bc11f7a20`. This is not a canonical Router UI package set or a new production candidate. No canonical product file was overwritten; native dependency/signature checks were not bypassed.

On the disposable OpenWrt24.10.5 VM: actual LuCI Check and auto-update on/off passed, followed by actual signed RC22 -> unchanged signed RC24 Apply. rpcd naturally expired the browser session; no forced session revocation was needed or performed. The fixed observer preserved LuCI's login dialog and avoided a false failure. Clicking its standard Log in action and authenticating again showed the real installed version, persistent Reboot required banner and blocked Apply. A real reboot reached native success/committed, then the banner disappeared. The final bounded post-login window had0 console errors and0 failed product requests. These are focused changed-view/RPC/ACL runtime results, not full candidate qualification or the full real-browser seven-state control matrix.

The test package was removed, VM powered off/snapshotted, owned browser/profile/server/serial helpers cleaned up, and the original seven-VM running set stayed equal. The physical spare remains recovered RC22 with lab VPN disabled; its production-candidate UI gate remains open. Safe local evidence: `output/reviews/router-ui-session-recovery-20261026/`. Harness schema/timing corrections are disclosed there; no second Apply/reboot or replacement source bytes were used to obtain the result.
