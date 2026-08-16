import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const censusPath = path.join(root, 'release/router-ui-control-census.json');
const aclPath = path.join(root, 'luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json');
const helperPath = path.join(root, 'luci-vpn-ui/files/usr/sbin/vpn-ui');
const readonlyPath = path.join(root, 'luci-vpn-ui/files/usr/sbin/vpn-ui-readonly');
const viewPaths = {
	update: path.join(root, 'luci-vpn-ui/files/www/luci-static/resources/view/system/update.js'),
	vpn: path.join(root, 'luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js'),
	tailscale: path.join(root, 'luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js')
};
const requiredFields = [
	'id', 'view', 'selector', 'applicable_states', 'expectation_profile',
	'rpc', 'acl', 'backend', 'success', 'failure', 'restoration'
];
const requiredControls = [
	'update-check', 'update-apply', 'vpn-adoption-preview', 'vpn-adoption-confirm-modal',
	'vpn-global-toggle', 'vpn-profile-add', 'vpn-profile-use-confirm', 'vpn-profile-delete',
	'vpn-subscription-import', 'vpn-subscription-sync', 'vpn-subscription-delete',
	'vpn-ping-refresh', 'vpn-auto-apply', 'vpn-direct-apply', 'vpn-device-toggle',
	'tailscale-apply', 'tailscale-peer-ping'
];
const allowedExpectations = new Set([
	'hidden', 'visible-enabled', 'visible-blocked-adoption-required',
	'visible-blocked-recovery', 'visible-blocked-reboot-pending',
	'visible-blocked-read-only', 'visible-conditionally-enabled',
	'visible-enabled-when-adoption-required-or-drifted',
	'visible-enabled-after-preview', 'visible-blocked-reboot-pending-after-preview',
	'visible-blocked-read-only-after-preview', 'hidden-until-invoked-then-enabled',
	'hidden-until-invoked-blocked-by-parent',
	'hidden-until-invoked-then-blocked-read-only'
]);

const census = JSON.parse(await fs.readFile(censusPath, 'utf8'));
const acl = JSON.parse(await fs.readFile(aclPath, 'utf8'))['luci-app-vpn-ui'];
const helper = await fs.readFile(helperPath, 'utf8');
const readonly = await fs.readFile(readonlyPath, 'utf8');
const sources = Object.fromEntries(await Promise.all(Object.entries(viewPaths).map(async ([view, file]) =>
	[view, await fs.readFile(file, 'utf8')]
)));

assert.equal(census.schema, 1);
assert.deepEqual(census.release, {
	application_version: '0.7.11-rc.16',
	package_version: '0.7.11~rc16-1',
	channel: 'candidate'
});
assert.equal(new Set(census.states).size, 7, 'all seven UI states must be unique');
assert.deepEqual(Object.keys(census.state_fixtures).sort(), [...census.states].sort(),
	'every top-level state must define its real-browser fixture contract');
for (const state of census.states) {
	const fixture = census.state_fixtures[state];
	assert.ok(Array.isArray(fixture.subfixtures) && fixture.subfixtures.length,
		`${state} must define configured/unconfigured subfixtures where applicable`);
	assert.ok(fixture.subfixtures.every(value => ['configured', 'unconfigured'].includes(value)),
		`${state} has an unknown subfixture`);
	assert.ok(fixture.ownership && fixture.mutation_policy,
		`${state} must define ownership and mutation policy`);
}

for (const [name, profile] of Object.entries(census.expectation_profiles)) {
	assert.deepEqual(Object.keys(profile).sort(), [...census.states].sort(),
		`${name} must resolve every required state`);
	for (const [state, expectation] of Object.entries(profile))
		assert.ok(allowedExpectations.has(expectation), `${name}/${state} has unknown expectation ${expectation}`);
}

const censusIds = [];
for (const control of census.controls) {
	for (const field of requiredFields)
		assert.ok(typeof control[field] === 'string' && control[field].length,
			`${control.id || '<missing id>'} must define ${field}`);
	assert.ok(sources[control.view], `${control.id} references unknown view ${control.view}`);
	assert.equal(control.selector, `[data-control-id="${control.id}"]`, `${control.id} selector must be stable`);
	assert.ok(census.expectation_profiles[control.expectation_profile],
		`${control.id} must resolve a state expectation profile`);
	assert.match(control.success, /./, `${control.id} must state a successful result`);
	assert.match(control.failure, /./, `${control.id} must state failure behavior`);
	assert.match(control.restoration, /restore|preserve|unchanged|preimage|byte-identical|returns|equal/i,
		`${control.id} must state an exact restoration assertion`);

	if (/luci-app-vpn-ui read/.test(control.acl)) {
		assert.deepEqual(acl.read.file['/usr/sbin/vpn-ui-readonly'], ['exec']);
		assert.equal(acl.read.file['/usr/sbin/vpn-ui'], undefined,
			'read ACL must never expose the mutation helper');
	}
	if (/luci-app-vpn-ui write/.test(control.acl)) {
		assert.deepEqual(acl.write.file['/usr/sbin/vpn-ui'], ['exec']);
		assert.deepEqual(acl.write.ubus.file, ['exec']);
	}
	for (const command of control.rpc.match(/(?:vpn-ui(?:-readonly)? )([a-z][a-z0-9-]+)/g) || []) {
		const name = command.split(' ').at(-1);
		assert.ok(helper.includes(`${name})`) || readonly.includes(`${name})`) ||
			helper.includes(`${name}|`) || readonly.includes(`${name}|`),
			`${control.id} RPC command ${name} must have a backend dispatch case`);
	}
	censusIds.push(control.id);
}

assert.equal(new Set(censusIds).size, censusIds.length, 'control IDs must be unique in the census');
assert.equal(censusIds.length, 46, 'RC16 authoritative census must contain exactly 46 controls');
for (const id of requiredControls)
	assert.ok(censusIds.includes(id), `required control ${id} must be in the census`);

const sourceIds = [];
for (const [view, source] of Object.entries(sources)) {
	for (const match of source.matchAll(/E\('(button|a|input|textarea)',/g)) {
		const nearby = source.slice(match.index, match.index + 240);
		assert.match(nearby, /'data-control-id': '[a-z0-9-]+'/,
			`${view}:${source.slice(0, match.index).split('\n').length} interactive element lacks a stable selector`);
	}
	for (const match of source.matchAll(/'data-control-id': '([a-z0-9-]+)'/g))
		sourceIds.push(match[1]);
	assert.match(source, /\.catch\(/, `${view} must render rejected backend responses without an uncaught promise`);
}

assert.deepEqual([...new Set(sourceIds)].sort(), [...censusIds].sort(),
	'every rendered control must be in the census and every census control must be rendered');

for (const id of censusIds) {
	const profile = census.expectation_profiles[census.controls.find(control => control.id === id).expectation_profile];
	for (const state of census.states) {
		const value = profile[state];
		assert.ok(value.startsWith('visible') || value.startsWith('hidden'),
			`${id}/${state} must define visibility`);
		assert.ok(value.includes('enabled') || value.includes('blocked') || value === 'hidden',
			`${id}/${state} must define enabled or blocked state`);
	}
}

console.log(`Router UI control census passed: ${census.controls.length} controls across ${census.states.length} states`);
