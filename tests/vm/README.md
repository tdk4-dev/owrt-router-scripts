# Router UI VM test architecture

The VM gate has three deliberately separate workflows:

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
   permission. The protected candidate and tagged release workflows use the
   same descriptor verification for their full gates.

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

Every VM is serial. QEMU receives `-m 256`; the harness records only the PID it
started, terminates and waits for that PID, and does not inspect other host QEMU
processes. Baseline consumers inject a fresh disposable SSH key and TLS CA over
the serial console, so no private key is stored in the baseline artifact.

## Manual selectors

`ROUTER_UI_VM_CASE` accepts `old-worker`, `rescue`, `protocol-v2`,
`clean-image`, `concurrency`, `storage`, `fault`, or `full`.
`ROUTER_UI_VM_SOURCE_VERSION` narrows old-worker or rescue runs. Storage phases
are `normal`, `near-reservation`, `below-reservation`, and `rd23-ubootmod`.
`ROUTER_UI_VM_FAULT_BOUNDARY` selects one power-loss boundary. Blank selectors
expand only inside an explicitly dispatched case.

The shared `fail-closed-runner.sh` logs every phase through one exact `tee`
child without a pipeline around the tested command. On failure it returns the
original command status and writes `failure.json` with candidate, harness,
baseline-pack, case, version, phase, fault, command, status, and mutation state.
Each phase has a 2,400-second deadline. Timeout returns 124, records the exact
QEMU PID and serial evidence, terminates the owned process tree, and waits for
it. Targeted diagnostic and single-version baseline jobs are capped at 90
minutes; only complete matrices/packs retain the 360-minute job cap.

Baseline artifacts and diagnostic artifacts are evidence, not release
authorization. Only a fresh protected candidate run from the final exact source
SHA can authorize merge, tag, draft, or publication.
