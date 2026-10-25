# Update observation after RPC session loss

Status: functional fix in progress; candidate identity/freeze/build/signing pending.
Base: fetched origin/main18562f49 plus ordinary RC24 lineage merge, isolated branch codex/router-ui-rc25-session-recovery. RC24 bytes remain immutable.

Changed surface: LuCI System > Update job observer and restored-page rendering. Risk: high (updater result/authentication integration); no ACL/authentication or package transaction semantics are relaxed.

Hardware reproducer: signed RC22 -> RC24 on owner spare OpenWrt24.10.8. Native apply, reboot commit, exact rollback/reboot and29 protected hashes passed. rpcd restart expired the browser session; the UI eventually hid LuCI's Log in modal and reported Update failed safely despite native success. Safe hardware evidence is retained outside Git in output/reviews/router-ui-rc24-transition-20261025/HARDWARE_CANARY.md; canonical incident INC-2026-10-26-02.

Acceptance: SessionError ends observation immediately and preserves LuCI's login dialog; an unknown observation result is never asserted to be a failed transaction. An authoritative failed exact job remains a failure. A fresh authenticated page must persistently display pending reboot and block another Apply until validation completes. Existing operation-ID/kind correlation and read-only ACL controls remain enforced.

Cheapest disprovers: mocked actual view with a LuCI SessionError after an accepted Apply, a transport interruption, a failed exact job, and a fresh pending-reboot native status. Retain red results on unchanged RC24. Then run relevant rendering/control/security tests and a single provisional disposable-VM real-browser checkpoint before freeze or double build/signing.

Legacy limitation: a new package cannot replace JavaScript already loaded by an RC22 browser tab. That first bridge hop may still show the legacy session-expiry behavior; its standard Log in path must recover onto the new page with truthful pending-reboot status. Do not claim seamless old-page session retention. Newly loaded fixed views must preserve the login action and avoid false safe-failure claims.

Invalidated evidence: RC24 source/package/VM/hardware acceptance cannot qualify changed UI bytes or a new candidate. Unchanged fixture/dependency caches and original RC24 reproducer evidence may be reused only as inputs/baselines. No production signing/publication/integration has been requested for this fix.

Primary LuCI contract: https://github.com/openwrt/luci/blob/openwrt-24.10/modules/luci-base/htdocs/luci-static/resources/luci.js — notifySessionExpiry displays the login modal then raises SessionError. The fix must preserve that authentication boundary.
