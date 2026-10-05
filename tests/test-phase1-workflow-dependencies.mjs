import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = file => fs.readFile(path.join(root, file), 'utf8');
const [ci, preflight, candidate, release, runner, historicalCandidate, historicalRelease, publisher] = await Promise.all([
	read('.github/workflows/ci.yml'),
	read('.github/workflows/router-ui-source-preflight.yml'),
	read('.github/workflows/validate-router-ui-candidate.yml'),
	read('.github/workflows/release-vpn-panel.yml'),
	read('tests/run-router-ui-source-preflight.sh'),
	read('docs/historical-workflows/validate-router-ui-candidate-rc15.yml'),
	read('docs/historical-workflows/release-vpn-panel-rc15.yml'),
	read('publish-vpn-panel-release.sh')
]);

const jobBlocks = source => {
	const result = {};
	const lines = source.split('\n');
	let current = null;
	for (const line of lines) {
		const match = line.match(/^  ([a-zA-Z0-9_-]+):\s*$/);
		if (match && match[1] !== 'jobs') {
			current = match[1];
			result[current] = '';
		}
		if (current) result[current] += `${line}\n`;
	}
	return result;
};
const dependencies = block => {
	const inline = block.match(/^    needs:\s*\[([^\]]+)\]/m);
	if (inline) return inline[1].split(',').map(value => value.trim());
	const scalar = block.match(/^    needs:\s*([a-zA-Z0-9_-]+)\s*$/m);
	return scalar ? [scalar[1]] : [];
};
const assertDangerousJobsGated = (source, workflowName) => {
	const jobs = jobBlocks(source);
	const reachesPreflight = (job, seen = new Set()) => {
		if (job === 'source-preflight') return true;
		if (seen.has(job) || !jobs[job]) return false;
		seen.add(job);
		return dependencies(jobs[job]).some(parent => reachesPreflight(parent, seen));
	};
	for (const [name, block] of Object.entries(jobs)) {
		if (!/build-openwrt|build-openwrt-ipks|sign-opkg|sign-release|production-signing|canonical-ipks|(?:^|-)image(?:-|:)/m.test(`${name}\n${block}`))
			continue;
		assert.ok(reachesPreflight(name), `${workflowName}/${name} must depend on exact-SHA preflight`);
	}
};

assert.match(ci, /^  pull_request:\s*$/m);
assert.match(ci, /^  workflow_dispatch:\s*$/m);
assert.match(ci, /^  push:\n    branches:\n      - main\s*$/m);
for (const duplicateBranch of ['codex/**', 'feat/**', 'fix/**', 'hotfix/**'])
	assert.equal(ci.includes(duplicateBranch), false, `feature push trigger must be absent: ${duplicateBranch}`);
assert.match(ci, /group: \$\{\{ github\.workflow \}\}-\$\{\{ github\.event\.pull_request\.number \|\| github\.ref \}\}/);
assert.match(ci, /cancel-in-progress: true/);
assert.equal((ci.match(/^  source-preflight:\s*$/gm) || []).length, 1,
	'ordinary CI must contain exactly one Tier 0 job');
assert.match(ci, /source_sha: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}/);

for (const forbidden of [
	'test-router-ui-release-v2.sh', 'test-updater-transaction-v2.sh',
	'build-openwrt-ipks.sh', 'build-openwrt-custom-image-linux.sh',
	'sign-opkg-feed.sh', 'router-ui-production-signing'
]) assert.equal(ci.includes(forbidden), false, `ordinary CI must not execute ${forbidden}`);

assert.match(preflight, /ref: \$\{\{ inputs\.source_sha \}\}/);
assert.match(preflight, /test "\$actual" = "\$EXPECTED_SOURCE_SHA"/);
assert.match(preflight, /verified_tree/);
assert.match(preflight, /TIER0_REPORT_PATH/);
assert.match(preflight, /product_build_invocations == 0/);
assert.match(preflight, /compiler_invocations == 0/);
assert.doesNotMatch(preflight, /apt-get|install-ci-usign|install-ci-ucode|cmake|libjson-c-dev/);

for (const requiredGuard of [
	'ROUTER_UI_TIER0_GUARD_LOG', 'product_build_invocations',
	'compiler_invocations', 'package_image_release_artifacts_generated',
	'git diff --check', 'EXPECTED_SOURCE_TREE'
]) assert.ok(runner.includes(requiredGuard), `Tier 0 runner lacks enforcement: ${requiredGuard}`);

assert.match(candidate, /source-preflight:[\s\S]*uses: \.\/\.github\/workflows\/router-ui-source-preflight\.yml/);
assert.match(candidate, /source_sha: \$\{\{ inputs\.source_sha \}\}/);
assert.match(candidate, /needs: \[validate-inputs, source-preflight\]/);
assert.match(candidate, /needs\.source-preflight\.outputs\.verified_sha == inputs\.source_sha/);
assertDangerousJobsGated(candidate, 'candidate');

for (const [source, label] of [[candidate, 'prepare'], [release, 'verify']]) {
	assert.match(source, /^  workflow_dispatch:/m);
	assert.doesNotMatch(source, /^  (push|pull_request|workflow_call):/m);
	assert.match(source, /contents: read/);
	assert.doesNotMatch(source, /contents: write|gh release|publish-vpn-panel-release\.sh|git tag|git push/);
	assert.doesNotMatch(source, /build-openwrt-custom-image|stage-factory|build-synthetic-next|validate-rc15|router-ui-vm-gate|REQUIRE_IMAGES: ['"]1['"]/);
	assert.match(source, /0\.7\.11-rc\.22:0\.7\.11~rc22-1:candidate\|0\.7\.11:0\.7\.11-1:stable/);
	assert.match(source, /verify-router-ui-package-candidate\.py artifacts/);
	assert.match(source, /--source-sha "\$SOURCE_SHA" --source-tree "\$SOURCE_TREE"/);
	assertDangerousJobsGated(source, label);
}
assert.match(candidate, /test "\$SOURCE_SHA" = "\$WORKFLOW_SHA"/);
assert.match(candidate, /test "\$CUSTODY_CONFIRMED" = true/);
assert.match(candidate, /custody_record_sha256:/);
assert.match(candidate, /"\$CUSTODY_RECORD_SHA256" \| grep -Eq '\^\[0-9a-f\]\{64\}\$'/);
assert.match(candidate, /matrix:\n        side: \[a, b\]/);
assert.match(candidate, /diff -ur "\$RUNNER_TEMP\/a\/ipk" "\$RUNNER_TEMP\/b\/ipk"/);
assert.match(candidate, /diff -ur "\$RUNNER_TEMP\/a\/feed" "\$RUNNER_TEMP\/b\/feed"/);
assert.match(candidate, /environment: router-ui-production-signing/);
assert.match(candidate, /inputs\.custody_confirmed && inputs\.custody_record_sha256 != ''/);
assert.match(candidate, /mktemp -d \/dev\/shm\/router-ui-signing/);
assert.match(candidate, /unset FACTORY_PRODUCT_VERSION/);
assert.match(candidate, /trap cleanup_secret EXIT\n/);
for (const [signal, code] of [['HUP', 129], ['INT', 130], ['TERM', 143]])
	assert.ok(candidate.includes(`trap 'exit ${code}' ${signal}`));
assert.match(candidate, /test ! -e "\$ROUTER_UI_SIGNING_KEY" && test ! -e "\$signing_dir"/);
assert.match(candidate, /cp -R "\$RUNNER_TEMP\/canonical\/build-provenance" "\$RUNNER_TEMP\/prepared\/"/);
for (const evidence of ['build-environment.txt', 'usign-binary.sha256', 'build-inputs.json',
	'dpkg-query -W', 'ImageOS', 'ImageVersion', 'workflow-provenance.json',
	'GITHUB_WORKFLOW_REF', 'GITHUB_RUN_ATTEMPT', 'no external feed or SDK'])
	assert.ok(candidate.includes(evidence), `preparation must retain ${evidence}`);
assert.equal((candidate.match(/\.\/scripts\/build-openwrt-ipks\.sh/g) || []).length, 1);
assert.match(release, /source_sha: \$\{\{ inputs\.source_sha \}\}/);
assert.match(release, /needs: \[validate-inputs, source-preflight\]/);
assert.match(release, /prepared-router-ui-package-candidate-/);
assert.match(release, /artifact_zip_sha256:/);
assert.match(release, /sha256sum -c -/);
assert.match(release, /\.path == "\.github\/workflows\/validate-router-ui-candidate\.yml"/);
assert.match(release, /\.conclusion == "success" and \.head_sha == \$source/);
assert.match(release, /python3 -I - <<'PY'/);
assert.match(release, /build_inputs_sha256\[\$side\] == \$digest/);
assert.match(release, /\.run_attempt == \(\$run\[0\]\.run_attempt \| tostring\)/);
assert.doesNotMatch(release, /ROUTER_UI_USIGN_SECRET_KEY|environment: router-ui-production-signing|build-openwrt-ipks|sign-opkg-feed|stage-router-release/);
assert.match(publisher, /0\.7\.11-rc\.22\|0\.7\.11\)/);
assert.match(publisher, /verify-router-ui-package-candidate\.py" artifacts/);
assert.match(publisher, /--source-sha "\$TAG_COMMIT" --source-tree/);
assert.match(publisher, /validate_release "\$RELEASE_DIR"/);
assert.match(publisher, /validate_release "\$VERIFY_DIR"/);
assert.match(publisher, /--latest=false/);
assert.match(historicalCandidate, /APP_VERSION: 0\.7\.11-rc\.15/);
assert.match(historicalRelease, /APP_VERSION: 0\.7\.11-rc\.15/);
assertDangerousJobsGated(historicalCandidate, 'historical candidate');
assertDangerousJobsGated(historicalRelease, 'historical release');

// Execute the real no-output input gate, without invoking builds, signing or hosts.
const inputBlock = jobBlocks(candidate)['validate-inputs'];
const gateMatch = inputBlock.match(/        run: \|\n((?:          .*\n|\n)+)/);
assert.ok(gateMatch, 'preparation input gate must be extractable');
const gate = gateMatch[1].split('\n').map(line => line.replace(/^          /, '')).join('\n');
const gateEnvironment = {
	PATH: process.env.PATH,
	APP_VERSION: '0.7.11-rc.22', PACKAGE_VERSION: '0.7.11~rc22-1', RELEASE_CHANNEL: 'candidate',
	SOURCE_SHA: 'a'.repeat(40), WORKFLOW_SHA: 'a'.repeat(40),
	CUSTODY_CONFIRMED: 'true', CUSTODY_RECORD_SHA256: 'b'.repeat(64)
};
const checkGate = (overrides, success) => {
	const result = spawnSync('sh', ['-eu', '-c', gate], {
		encoding: 'utf8', env: { ...gateEnvironment, ...overrides }
	});
	assert.equal(result.error, undefined);
	assert.equal(result.status === 0, success, `gate result for ${JSON.stringify(overrides)}: ${result.stderr}`);
};
checkGate({}, true);
checkGate({APP_VERSION: '0.7.11', PACKAGE_VERSION: '0.7.11-1', RELEASE_CHANNEL: 'stable'}, true);
for (const overrides of [
	{CUSTODY_CONFIRMED: 'false'}, {CUSTODY_RECORD_SHA256: ''}, {CUSTODY_RECORD_SHA256: 'b'.repeat(63)},
	{CUSTODY_RECORD_SHA256: 'g'.repeat(64)}, {WORKFLOW_SHA: 'c'.repeat(40)}, {SOURCE_SHA: 'main'},
	{APP_VERSION: '0.7.11-rc.15', PACKAGE_VERSION: '0.7.11~rc15-1'},
	{APP_VERSION: '0.7.11'}, {RELEASE_CHANNEL: 'stable'}
]) checkGate(overrides, false);
console.log('Exact-SHA preflight, custody-gated package preparation, retained verification and historical separation passed');
