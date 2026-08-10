# Router UI VM test architecture

The test architecture has four deliberately separate workflows:

1. Ordinary push/pull-request CI runs shell, unit, and fixture-contract tests.
   It never invokes production signing or a VM workflow.
2. `build-router-ui-legacy-baselines.yml` is manually dispatched for one pinned
   source version or `all`. It downloads inputs named in
   `legacy-baseline-lock.json`, builds one OpenWrt base per RD23-derived writable
   geometry, installs each published legacy release once, runs that release's
   own validator, and emits compact qcow2 overlays plus a complete manifest.
3. `diagnose-router-ui-vm.yml` is manually dispatched with only the candidate
   artifact ID/digest, baseline artifact ID/digest, and case selectors. The
   selected workflow ref is the harness commit. Run IDs, artifact names,
   product/builder commits, manifest hashes, and signing provenance are derived
   into immutable descriptor files and checked against the downloaded bytes.
   Diagnostic mode rebuilds nothing and has no signing or publication
   permission. Its QEMU results never authorize an RC6 candidate or release.
4. `publish-router-ui-rc6-virtualbox-evidence.yml` runs only on the protected
   self-hosted Mac Pro runner. It validates and publishes an already-supervised
   VirtualBox evidence bundle for the exact source SHA. The protected candidate
   consumes that immutable artifact and refuses QEMU-backed evidence; the tagged
   release accepts only a successful pre-tag candidate whose VirtualBox-only job
   passed.

Baseline compatibility is the digest emitted by
`baseline-contract-digest.sh`, not equality between the baseline builder and
product commits. Its inputs are limited to the baseline lock and fixture tree,
VM gate/guest/fail-closed runner, package list, RD23 geometry, and x86 image
patching input. The builder commit remains separate provenance in the baseline
descriptor and manifest. Every baseline guest must match the Xray binary hash
derived from the exact locked Xray IPK before its own legacy validator can pass.

Post-0.7.11 CI improvement: split immutable baseline-content compatibility
from consumer-harness identity. The 0.7.11 release deliberately retains the
single digest contract, so a VM gate or guest harness change requires one new
self-validated baseline pack.

Every diagnostic QEMU VM is serial. QEMU receives `-m 256`; the harness records
only the PID it started, terminates and waits for that PID, and does not inspect
other host QEMU processes. Baseline consumers inject a fresh disposable SSH key
and TLS CA over the serial console, so no private key is stored in the baseline
artifact. These diagnostics are not RC6 release evidence.

## Manual selectors

`ROUTER_UI_VM_CASE` accepts `old-worker`, `rescue`, `protocol-v2`,
`clean-image`, `dual-daemon`, `concurrency`, `storage`, `fault`, or `full`.
`ROUTER_UI_VM_SOURCE_VERSION` narrows old-worker or rescue runs. Storage phases
are `normal`, `near-reservation`, `below-reservation`, and `rd23-ubootmod`.
`ROUTER_UI_VM_FAULT_BOUNDARY` selects one power-loss boundary. Blank selectors
expand only inside an explicitly dispatched case.

The `dual-daemon` case boots the exact candidate x86 image with 256 MiB RAM,
runs the installed `tailscaled` process without enrolling it, and runs the
installed Xray binary with a non-secret loopback-only SOCKS configuration. It
samples process RSS, available memory, writable-space headroom, Router UI
status, local Xray traffic, and OOM evidence before and after a real reboot.
This is x86 VM resource and persistence evidence only. It is not RD23 hardware
proof, does not prove a Tailscale control-plane session, and does not authorize
contact with a physical router.

The shared `fail-closed-runner.sh` logs every phase through one exact `tee`
child without a pipeline around the tested command. On failure it returns the
original command status and writes `failure.json` with candidate, harness,
baseline-pack, case, version, phase, fault, command, status, and mutation state.
Each phase has a 2,400-second deadline. Timeout returns 124, records the exact
QEMU PID and serial evidence, terminates the owned process tree, and waits for
it. Targeted diagnostic and single-version baseline jobs are capped at 90
minutes; only complete matrices/packs retain the 360-minute job cap.

Baseline and QEMU diagnostic artifacts are not release authorization. RC6
authorization requires the final exact source SHA, production fingerprint
`d055711acf1d9a5b`, and an immutable supervised Mac Pro VirtualBox evidence
bundle that passes `validate-rc6-virtualbox-evidence.sh`.
