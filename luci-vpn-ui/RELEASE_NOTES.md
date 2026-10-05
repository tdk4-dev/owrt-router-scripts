# Router UI 0.7.11 RC23 — Tailscale restoration lifecycle

Application `0.7.11-rc.23`, package `0.7.11~rc23-1`, candidate channel.

- Wait for asynchronous procd stop completion before restoring Tailscale state.
- Distinguish restoration failure stages and make a bounded final recovery
  attempt for the original running intent after an accepted stop.
- Preserve boot intent, identity/state hashes and strict route invariants.
  Refuse detectable damaged kernel baselines before restart; never equate
  restored identity with reconstructed kernel routing.

All other RC22 behavior is unchanged. This candidate needs its own focused
native qualification and immutable signed hashes. Hardware and full historical
release-matrix qualification are separate; this is not a published release.

Scope: [RC23 decision](../docs/decisions/2026-10-05-router-ui-0.7.11-rc23-tailscale-restoration.md).
