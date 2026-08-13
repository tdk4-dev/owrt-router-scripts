import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = file => fs.readFile(path.join(root, file), 'utf8');
const [ci, preflight, candidate, release, runner] = await Promise.all([
	read('.github/workflows/ci.yml'),
	read('.github/workflows/router-ui-source-preflight.yml'),
	read('.github/workflows/validate-router-ui-candidate.yml'),
	read('.github/workflows/release-vpn-panel.yml'),
	read('tests/run-router-ui-source-preflight.sh')
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

assert.match(release, /resolve-source:[\s\S]*source-preflight:/);
assert.match(release, /source_sha: \$\{\{ needs\.resolve-source\.outputs\.source_sha \}\}/);
assert.match(release, /needs: \[resolve-source, source-preflight\]/);
assert.match(release, /needs\.source-preflight\.outputs\.verified_sha == needs\.resolve-source\.outputs\.source_sha/);
assertDangerousJobsGated(release, 'release');

console.log('Exact-SHA Tier 0 gating, feature-CI de-duplication, and downstream dependency tests passed');
