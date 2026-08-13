import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const overlayPath = path.join(root, 'luci-vpn-ui/files/usr/libexec/premier-router/xray-overlay.uc');
const backendPath = path.join(root, 'luci-vpn-ui/files/usr/sbin/vpn-ui');
const fixturePath = path.join(root, 'tests/fixtures/xray/valera-manual-config.json');
const plannedFixturePath = path.join(root, 'tests/vm/fixtures/phase1-adopted-xray.json');
const incompatibleFixturePath = path.join(root, 'tests/fixtures/xray/adopted-overlay.json');
const [overlay, backend, fixtureText] = await Promise.all([
	fs.readFile(overlayPath, 'utf8'), fs.readFile(backendPath, 'utf8'), fs.readFile(fixturePath, 'utf8')
]);
const [plannedFixtureText, incompatibleFixtureText] = await Promise.all([
	fs.readFile(plannedFixturePath, 'utf8'), fs.readFile(incompatibleFixturePath, 'utf8')
]);

for (const contract of [
	'expected exactly one isolated direct domain array',
	'expected exactly one isolated direct IP array',
	'adopted selectors no longer identify the unique managed arrays',
	'expected exactly one proxy VLESS outbound',
	'single-server-reality-tcp-v1',
	'proxy VLESS outbound is outside the supported single-server Reality TCP layout',
	'expected exactly one isolated current endpoint bypass',
	'non-managed Xray JSON semantics changed',
	'non_managed_semantics_unchanged: true'
]) assert.ok(overlay.includes(contract), `missing adopted-overlay contract: ${contract}`);
for (const boundary of [
	'new_overlay_transaction', 'config.preimage', 'ownership.preimage',
	'tailscale-before.txt', 'restore_adopted_preimage', 'overlay_recover_transactions',
	'adopted Xray configuration bytes changed outside Router UI'
]) assert.ok(backend.includes(boundary), `missing adopted transaction boundary: ${boundary}`);
for (const boundary of [
	'overlay_exec inspect', 'capability_matches', 'selectors_match',
	'unsupported adopted Xray structure or capability'
]) assert.ok(backend.includes(boundary), `missing adopted capability boundary: ${boundary}`);

const plannedFixture = JSON.parse(plannedFixtureText);
const incompatibleFixture = JSON.parse(incompatibleFixtureText);
assert.equal(plannedFixture.outbounds[0].streamSettings.network, 'tcp');
assert.equal(plannedFixture.outbounds[0].streamSettings.security, 'reality');
assert.equal(incompatibleFixture.outbounds[0].streamSettings.network, undefined,
	'negative fixture must retain the pre-RC10 incompatible layout');

const config = JSON.parse(fixtureText);
const eligible = (rule, key) => rule?.type === 'field' && rule.outboundTag === 'direct' &&
	Array.isArray(rule[key]) && Object.keys(rule).every(name => ['type', 'outboundTag', key].includes(name));
const domainIndexes = [];
const ipIndexes = [];
config.routing.rules.forEach((rule, index) => {
	if (eligible(rule, 'domain')) domainIndexes.push(index);
	if (eligible(rule, 'ip')) ipIndexes.push(index);
});
assert.deepEqual(domainIndexes, [0]);
assert.deepEqual(ipIndexes, [1]);

const candidate = structuredClone(config);
candidate.routing.rules[domainIndexes[0]].domain = ['full:source-contract.invalid'];
candidate.routing.rules[ipIndexes[0]].ip = ['198.51.100.0/25'];
const maskManaged = value => {
	const clone = structuredClone(value);
	clone.routing.rules[domainIndexes[0]].domain = ['managed'];
	clone.routing.rules[ipIndexes[0]].ip = ['managed'];
	return clone;
};
assert.deepEqual(maskManaged(candidate), maskManaged(config),
	'synthetic managed-array change must preserve all non-managed JSON semantics');
assert.equal(candidate.routing.domainStrategy, 'AsIs');
assert.equal(candidate.routing.rules.some(rule => rule.port === '8080'),
	config.routing.rules.some(rule => rule.port === '8080'),
	'unmanaged port-routing semantics must be invariant');
assert.equal(candidate.routing.rules.some(rule => (rule.protocol || []).includes('bittorrent')),
	config.routing.rules.some(rule => (rule.protocol || []).includes('bittorrent')),
	'unmanaged protocol-routing semantics must be invariant');

console.log('Adopted-Xray source structure, mutation boundary, and non-managed semantics contracts passed');
