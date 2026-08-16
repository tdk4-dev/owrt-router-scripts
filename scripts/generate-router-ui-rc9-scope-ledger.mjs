#!/usr/bin/env node

import { execFileSync, spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BASE = '18562f49bcac914acf3b07749f5b8863d8016e00';
const PR24 = '97da893062ebed1e27e9b35dbf0b68f248c12dd7';
const PR20 = 'f1c8bf0eb81a663340351276f3cafd3fdeab53f5';
const outputArgument = process.argv.indexOf('--output');
if (outputArgument >= 0 && !process.argv[outputArgument + 1])
  throw new Error('--output requires a path');
const OUTPUT = outputArgument >= 0
  ? resolve(process.argv[outputArgument + 1])
  : resolve(ROOT, 'docs/evidence/router-ui-0.7.11-rc9-scope-ledger.json');

function git(args) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8' }).trim();
}

function blob(commit, filePath) {
  const spec = commit + ':' + filePath;
  if (spawnSync('git', ['cat-file', '-e', spec], { cwd: ROOT }).status !== 0)
    return null;
  return git(['rev-parse', spec]);
}

const deferred = new Set([
  'image-overlay/usr/sbin/router-prep',
  'image-overlay/www/cgi-bin/router-prep',
  'image-overlay/www/index.html',
  'image-overlay/www/premier-router-index.html',
  'image-overlay/www/prepare/app.js',
  'image-overlay/www/prepare/index.html',
  'image-overlay/www/prepare/styles.css',
  'luci-vpn-ui/files/usr/share/luci/menu.d/luci-app-vpn-ui.json',
  'luci-vpn-ui/files/www/luci-static/resources/tools/router_footer.js',
  'luci-vpn-ui/files/www/luci-static/resources/view/network/adguard.js',
  'luci-vpn-ui/files/www/luci-static/resources/view/system/reset.js',
  'tests/test-adguard-panel.sh',
  'tests/test-firstboot-install-options.sh',
  'tests/test-firstboot-wifi.sh',
  'tests/test-luci-status-include.sh',
  'tests/test-router-prep-policy.sh',
  'tests/test-router-reset-ui.sh'
]);

const preserveMain = new Set([
  'README.md',
  'firstboot-wizard/README.md',
  'firstboot-wizard/server.mjs',
  'firstboot-wizard/www/app.js',
  'firstboot-wizard/www/index.html',
  'firstboot-wizard/www/styles.css',
  'image-overlay/etc/uci-defaults/99-openwrt-fin0-firstboot',
  'image-overlay/www/cgi-bin/firstboot-setup',
  'image/openwrt-rd23-packages.txt',
  'luci-vpn-ui/files/etc/config/premier_router',
  'luci-vpn-ui/files/www/luci-static/resources/view/status/include/35_vpn.js',
  'tests/test-luci-stable-assets.sh',
  'tests/test-openwrt-ipk-packages.sh',
  'tests/test-rd23-profile.sh',
  'tests/test-router-metadata.sh',
  'tests/test-tailscale-registration.sh',
  'tests/test-firstboot-root-only.sh',
  'tests/test-firstboot-vless-import.sh',
  'tests/test-version-variable-names.sh'
]);

// Every inherited PR #24 trust/update path is intentionally enumerated. Any
// new or omitted path falls into classification 6 and stops ledger generation.
const trustUpdate = new Set([
  '.github/workflows/build-router-ui-legacy-baselines.yml',
  '.github/workflows/diagnose-router-ui-vm.yml',
  '.github/workflows/release-vpn-panel.yml',
  '.github/workflows/validate-router-ui-candidate.yml',
  'bootstrap-router-ui-ipk-install.sh',
  'build-openwrt-custom-image-linux.sh',
  'build-openwrt-x86-fin0-image-linux.sh',
  'docs/custom-image-release-guide.md',
  'docs/historical-rescue-support-matrix.md',
  'docs/legacy-router-ui-recovery.md',
  'docs/local-rc-publication-checklist.md',
  'docs/local-signing-key-lifecycle.md',
  'docs/package-first-release-architecture.md',
  'docs/release-checklist.md',
  'docs/router-ui-0.7.11-transition.md',
  'docs/router-ui-update-transition-matrix.md',
  'docs/update-protocol-v2.md',
  'image/openwrt-fin0-packages.txt',
  'install-friend-vpn-panel.sh',
  'install-openwrt-vpn-ui.sh',
  'install-router-ui-release.sh',
  'luci-vpn-ui/README.md',
  'luci-vpn-ui/files/etc/init.d/premier-router-update-recovery',
  'luci-vpn-ui/files/usr/libexec/premier-router/candidate-validator',
  'luci-vpn-ui/files/usr/libexec/premier-router/update-lib.sh',
  'luci-vpn-ui/files/usr/sbin/vpn-ui-update',
  'luci-vpn-ui/install.sh',
  'make-vpn-ui-release-bundle.sh',
  'publish-vpn-panel-release.sh',
  'release/compat/0.7.9/_35_vpn.js',
  'release/keys/production-2026-07.fingerprint',
  'release/keys/production-2026-07.pub',
  'release/keys/trusted-keys.json',
  'rescue-router-ui.sh',
  'scripts/build-openwrt-ipks.sh',
  'scripts/create-local-rc-bundle.sh',
  'scripts/install-ci-ucode.sh',
  'scripts/release-key-lib.sh',
  'scripts/sign-in-linux-build-vm.sh',
  'scripts/sign-opkg-feed.sh',
  'scripts/sign-release-inputs.sh',
  'scripts/stage-factory-schema2-contract.sh',
  'scripts/stage-installed-package-set.sh',
  'scripts/stage-router-release.sh',
  'scripts/validate-staged-release.sh',
  'scripts/verify-release-signature.sh',
  'tests/fixtures/keys/router-ui-test.pub',
  'tests/integration/https-artifact-server.rb',
  'tests/integration/repro-recovery-lock-mac-pro.sh',
  'tests/integration/repro-recovery-lock.sh',
  'tests/integration/run-router-ui-virtualbox-matrix-mac-pro.sh',
  'tests/integration/run-vanilla-ipk-install-mac-pro.sh',
  'tests/test-candidate-evidence-aggregation.sh',
  'tests/test-factory-schema2-staging.sh',
  'tests/test-image-package-identity.sh',
  'tests/test-local-signing-key-lifecycle.sh',
  'tests/test-recovery-lock-reproducer.sh',
  'tests/test-release-publisher.sh',
  'tests/test-release-staging.sh',
  'tests/test-rescue-support-matrix.sh',
  'tests/test-router-ui-release-v2.sh',
  'tests/test-tailscale-ping-ui.mjs',
  'tests/test-update-release-compat.sh',
  'tests/test-updater-transaction-v2.sh',
  'tests/test-updater-worker-start.sh',
  'tests/test-vm-architecture.sh',
  'tests/test-vm-controller-contract.sh',
  'tests/test-vm-listener-normalization.sh',
  'tests/test-vm-recovery-readiness.sh',
  'tests/vm/README.md',
  'tests/vm/aggregate-candidate-evidence.sh',
  'tests/vm/baseline-contract-digest.sh',
  'tests/vm/build-synthetic-next.sh',
  'tests/vm/download-immutable-actions-artifact.sh',
  'tests/vm/fail-closed-runner.sh',
  'tests/vm/legacy-baseline-lock.json',
  'tests/vm/legacy-diagnostic-candidates.json',
  'tests/vm/normalize-listeners.awk',
  'tests/vm/recovery-readiness.sh',
  'tests/vm/router-ui-vm-gate.sh',
  'tests/vm/router-ui-vm-guest.sh',
  'tests/vm/run-preimage-rescue-smoke.sh',
  'tests/vm/write-candidate-content-descriptor.sh'
]);

const phase1 = new Set([
  '.github/workflows/ci.yml',
  '.github/workflows/publish-router-ui-rc7-virtualbox-evidence.yml',
  '.github/workflows/router-ui-source-preflight.yml',
  '.gitignore',
  'docs/evidence/router-ui-0.7.11-phase-1-independent-review.md',
  'docs/evidence/router-ui-0.7.11-phase-1-source-record.md',
  'docs/issue-10-rc-status-template.md',
  'docs/ordinary-user-ipk-installation.md',
  'docs/templates/router-ui-install-guide-template.json',
  'docs/vm-release-testing-methodology.md',
  'luci-vpn-ui/PACKAGE_VERSION',
  'luci-vpn-ui/RELEASE_NOTES.md',
  'luci-vpn-ui/VERSION',
  'luci-vpn-ui/files/usr/share/vpn-ui/version',
  'luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js',
  'luci-vpn-ui/files/www/luci-static/resources/view/system/update.js',
  'release/router-ui-control-census.json',
  'release/router-ui-release-rules.json',
  'release/transition-matrix.json',
  'scripts/render-router-ui-install-guide.py',
  'tests/fixtures/release/router-ui-0.7.11-rc7-provisional-manifest.json',
  'tests/integration/validate-rc7-virtualbox-evidence.sh',
  'tests/run-router-ui-source-preflight.sh',
  'tests/test-phase1-workflow-dependencies.mjs',
  'tests/test-rc7-virtualbox-evidence.sh',
  'tests/test-router-ui-collateral.py',
  'tests/test-router-ui-control-census.mjs',
  'tests/test-router-ui-state-rendering.mjs'
]);

function isAdoptedOverlay(filePath) {
  return filePath === 'luci-vpn-ui/files/usr/libexec/premier-router/xray-overlay.uc' ||
    filePath === 'luci-vpn-ui/files/usr/sbin/vpn-ui' ||
    filePath === 'luci-vpn-ui/files/usr/sbin/vpn-ui-readonly' ||
    filePath === 'luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json' ||
    filePath === 'luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js' ||
    filePath.startsWith('tests/fixtures/xray/') ||
    filePath === 'tests/test-security-boundaries-0.7.11.sh' ||
    filePath === 'tests/test-vpn-hotfixes.sh' ||
    filePath === 'tests/test-vpn-luci-adopted-apply.mjs' ||
    filePath === 'tests/test-xray-adopted-overlay.sh';
}

function classification(filePath) {
  if (deferred.has(filePath)) return 4;
  if (preserveMain.has(filePath)) return 5;
  if (phase1.has(filePath)) return 3;
  if (isAdoptedOverlay(filePath)) return 2;
  if (trustUpdate.has(filePath)) return 1;
  return 6;
}

const citations = {
  1: {
    source: 'docs/RELEASE_SCOPE_0.7.11_TO_0.8.0.md:123-161',
    rule: '0.7.11 is the trust/update bridge; protocol 2, transactions, rollback, trust root, security, and three package deliverables are required.'
  },
  2: {
    source: 'docs/decisions/2026-08-11-router-ui-0.7.11-phase-0.md:123-161',
    rule: 'The adopted-overlay work is an approved narrow regression repair with fail-closed state and exact restoration requirements.'
  },
  3: {
    source: 'docs/RELEASE_SCOPE_0.7.11_TO_0.8.0.md:16-20,62-98,209-220',
    rule: 'Candidate identity, evidence, source tests, workflow gates, and immutable-byte rules are required for the current RC.'
  },
  4: {
    source: 'docs/RELEASE_SCOPE_0.7.11_TO_0.8.0.md:195-207; docs/decisions/2026-08-11-router-ui-0.7.11-phase-0.md:183-198',
    rule: '0.7.11 must exclude Router UI 0.8 navigation/page architecture, new product pages, dynamic AdGuard installation, and new onboarding/setup flows.'
  },
  5: {
    source: 'owner continuation decision Product rollback; docs/RELEASE_SCOPE_0.7.11_TO_0.8.0.md:62-117',
    rule: 'Unrelated current-main safety, metadata, registry, relay, and generic infrastructure must be preserved unless an explicit 0.8-only non-goal applies.'
  },
  6: {
    source: 'no reviewed mapping',
    rule: 'Unclassified inherited paths are unexplained and are a binding stop.'
  }
};

function deferredEffect(filePath) {
  if (filePath.includes('adguard'))
    return 'Excludes the 0.8 AdGuard product page or dynamic installation behavior; existing installed-service compatibility is not removed.';
  if (filePath.includes('reset'))
    return 'Excludes the 0.8 Reset-to-setup product page and its new onboarding handoff.';
  if (filePath.includes('router_footer') || filePath.includes('luci-status'))
    return 'Excludes the 0.8 shared footer/navigation presentation while underlying non-secret ownership metadata is preserved separately.';
  if (filePath.endsWith('luci-app-vpn-ui.json'))
    return 'Keeps the established VPN, Tailscale, and Update routes while excluding the new AdGuard and Reset product-page routes.';
  if (filePath.includes('router-prep') || filePath.includes('/prepare/'))
    return 'Excludes the 0.8 owner-preparation and seal workflow as a new onboarding/product surface.';
  return 'Excludes the 0.8 first-boot, progress, recovery, or onboarding UX while retaining the earlier 0.7.11 setup baseline needed by the setup IPK.';
}

function currentMainEffect(filePath) {
  const effects = {
    'README.md': 'Preserve current-main product, registry, ownership, and release-state documentation; apply only truthful RC9 Phase 1 deltas.',
    'firstboot-wizard/README.md': 'Preserve the setup-IPK firstboot surface while excluding new 0.8 installation and onboarding features.',
    'firstboot-wizard/server.mjs': 'Preserve a secret-redacted firstboot simulator, including the supported no-AdGuard package path.',
    'firstboot-wizard/www/app.js': 'Preserve the setup-IPK firstboot UI and make optional AdGuard availability explicit.',
    'firstboot-wizard/www/index.html': 'Preserve the existing setup-IPK firstboot document shell.',
    'firstboot-wizard/www/styles.css': 'Preserve styling required by the existing setup-IPK firstboot UI.',
    'image-overlay/etc/uci-defaults/99-openwrt-fin0-firstboot': 'Preserve root-only firstboot routing into the setup-IPK assistant.',
    'image-overlay/www/cgi-bin/firstboot-setup': 'Preserve firstboot configuration while making no-AdGuard completion and registered Tailscale fail closed.',
    'image/openwrt-rd23-packages.txt': 'Preserve the lean RD23 profile and AdGuard exclusion while retaining only dependencies required by the 0.7.11 trust/update bridge.',
    'luci-vpn-ui/files/etc/config/premier_router': 'Preserve non-secret Router UI installation, ownership, support, and registration metadata defaults.',
    'luci-vpn-ui/files/www/luci-static/resources/view/status/include/35_vpn.js': 'Preserve the stable VPN status include and avoid restoring the excluded 0.8 footer coupling.',
    'tests/test-luci-stable-assets.sh': 'Preserve stable, unversioned LuCI asset routing and legacy cleanup guards.',
    'tests/test-openwrt-ipk-packages.sh': 'Preserve package-content and metadata safety assertions, but move real package construction out of Tier 0 and into the sole Tier 1 checkpoint.',
    'tests/test-rd23-profile.sh': 'Preserve the lean RD23 and no-AdGuard policy without depending on deferred 0.8 onboarding files.',
    'tests/test-router-metadata.sh': 'Preserve ownership metadata behavior with RC9 identity and without restoring deferred owner-preparation UI.',
    'tests/test-tailscale-registration.sh': 'Preserve registered-running verification and secret-safe temporary-log behavior for Tailscale setup.',
    'tests/test-firstboot-root-only.sh': 'Preserve the root-only firstboot account safety contract.',
    'tests/test-firstboot-vless-import.sh': 'Preserve the existing firstboot VLESS import safety contract without adding 0.8 onboarding behavior.',
    'tests/test-version-variable-names.sh': 'Preserve generic APP_VERSION and OPENWRT_VERSION naming guards.'
  };
  return effects[filePath];
}

function effect(filePath, cls) {
  if (cls === 4) return deferredEffect(filePath);
  if (cls === 5) return currentMainEffect(filePath);
  if (cls === 3) return 'Defines RC identity, Phase 1 source tests, control-census contracts, workflow gating, documentation, or evidence without authorizing release work.';
  if (cls === 2) return 'Implements or verifies the approved healthy-adopted control surface, fail-closed states, ACL boundary, mutation transaction, and exact restoration.';
  if (cls === 1) return 'Implements or verifies the 0.7.11 trust/update bridge, package boundary, release-safety contract, updater recovery, or diagnostic infrastructure.';
  return 'Unexplained inherited path; Phase 1 must stop until an explicit reviewed mapping is added.';
}

function decision(filePath, cls) {
  if (cls === 6) return 'unexplained';
  if (cls === 4 && filePath.endsWith('luci-app-vpn-ui.json')) return 'reimplement';
  if (cls === 4) return 'exclude';
  if (cls === 5) {
    if (filePath === 'luci-vpn-ui/files/etc/config/premier_router' ||
        filePath === 'tests/test-tailscale-registration.sh' ||
        filePath === 'tests/test-version-variable-names.sh') return 'preserve';
    return 'reimplement';
  }
  if (cls === 3) return 'reimplement';
  if (filePath === 'luci-vpn-ui/files/usr/sbin/vpn-ui') return 'reimplement';
  return 'preserve';
}

const changed = git(['diff', '--name-status', BASE, PR24]).split('\n').filter(Boolean);
const entries = changed.map((line) => {
  const tab = line.indexOf('\t');
  const changeStatus = line.slice(0, tab);
  const filePath = line.slice(tab + 1);
  const cls = classification(filePath);
  const baseBlob = blob(BASE, filePath);
  const pr24Blob = blob(PR24, filePath);
  const pr20Blob = blob(PR20, filePath);
  return {
    path: filePath,
    pr24_change_status: changeStatus,
    base_blob: baseBlob,
    pr24_blob: pr24Blob,
    pr20_blob: pr20Blob,
    pr24_final_state_byte_identical_to_pr20: pr24Blob === pr20Blob,
    classification: cls,
    classification_name: [
      null,
      'approved 0.7.11 trust/update bridge',
      'approved adopted-overlay regression repair',
      'RC identity, tests, workflow, documentation, or evidence required by Phase 1',
      'explicitly deferred Router UI 0.8-only surface',
      'current-main functionality or infrastructure that must be preserved'
      ,'unexplained or scope-conflicting path'
    ][cls],
    governing_scope_citation: citations[cls],
    user_visible_or_operational_effect: effect(filePath, cls),
    rc9_decision: decision(filePath, cls),
    review_status: cls === 6 ? 'unexplained' : 'reviewed-explicit-mapping'
  };
});

const sameCount = entries.filter((entry) => entry.pr24_final_state_byte_identical_to_pr20).length;
const classifications = Object.fromEntries([1, 2, 3, 4, 5, 6].map((number) => [
  String(number), entries.filter((entry) => entry.classification === number).length
]));
if (entries.length !== 158) throw new Error('expected 158 PR #24 paths, found ' + entries.length);
if (sameCount !== 104) throw new Error('expected 104 PR #20-identical final states, found ' + sameCount);
if (classifications['6'] !== 0) throw new Error('unexplained or scope-conflicting paths remain');
if (entries.some((entry) => !entry.user_visible_or_operational_effect || !entry.rc9_decision))
  throw new Error('ledger entry is missing effect or decision');

const ledger = {
  schema_version: 1,
  generated_from: {
    origin_main_commit: BASE,
    origin_main_tree: git(['rev-parse', BASE + '^{tree}']),
    failed_rc7_pr_number: 24,
    failed_rc7_head: PR24,
    failed_rc7_tree: git(['rev-parse', PR24 + '^{tree}']),
    historical_pr20_head: PR20,
    historical_pr20_tree: git(['rev-parse', PR20 + '^{tree}'])
  },
  summary: {
    inherited_path_count: entries.length,
    pr20_byte_identical_final_state_count: sameCount,
    pr20_different_final_state_count: entries.length - sameCount,
    classification_counts: classifications,
    unexplained_or_scope_conflicting_count: classifications['6'],
    decision_counts: Object.fromEntries(['preserve', 'exclude', 'reimplement'].map((name) => [
      name, entries.filter((entry) => entry.rc9_decision === name).length
    ]))
  },
  audit_rules: {
    allowed_classifications: [1, 2, 3, 4, 5, 6],
    stop_if_classification_6_present: true,
    historical_evidence_files_are_immutable: true,
    scope_document_sha256: '795065bc4a9555ef283903ee757b9076d7cbfff6261d24bd1eda8258e1b8ff82'
  },
  entries
};

writeFileSync(OUTPUT, JSON.stringify(ledger, null, 2) + '\n');
console.log('wrote ' + OUTPUT);
console.log(JSON.stringify(ledger.summary));
