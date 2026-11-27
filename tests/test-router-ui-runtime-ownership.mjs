import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ownership = JSON.parse(await fs.readFile(path.join(root, 'release/router-ui-runtime-ownership.json'), 'utf8'));
const summary = await fs.readFile(path.join(root, 'release/router-ui-runtime-ownership.md'), 'utf8');
const controls = JSON.parse(await fs.readFile(path.join(root, 'release/router-ui-control-census.json'), 'utf8'));
const builder = await fs.readFile(path.join(root, 'scripts/build-openwrt-ipks.sh'), 'utf8');
const sources = (await Promise.all([
  'luci-vpn-ui/files/usr/sbin/vpn-ui',
  'luci-vpn-ui/files/usr/sbin/vpn-ui-readonly',
  'luci-vpn-ui/files/usr/sbin/vpn-ui-update',
  'image-overlay/www/cgi-bin/firstboot-setup'
].map(file => fs.readFile(path.join(root, file), 'utf8')))).join('\n');

assert.equal(ownership.schema, 1);
assert.deepEqual(ownership.release, controls.release,
  'control and runtime censuses must describe the same immutable candidate identity');
assert.deepEqual(ownership.canonical_project_packages, [
  'premier-router-core', 'luci-app-premier-router', 'premier-router-setup'
]);
for (const packageName of ownership.canonical_project_packages)
  assert.ok(summary.includes(`\`${packageName}\``), `concise census must name ${packageName}`);

const controlIds = controls.controls.map(control => control.id).sort();
const groupedControlIds = ownership.control_groups.flatMap(group => group.controls).sort();
assert.deepEqual(groupedControlIds, controlIds,
  'every visible LuCI control must have exactly one runtime dependency group');
assert.equal(new Set(groupedControlIds).size, groupedControlIds.length,
  'visible controls must not have ambiguous runtime dependency groups');

const objects = new Map();
for (const object of ownership.runtime_objects) {
  assert.ok(object.id && object.kind && object.owner && object.availability,
    `runtime object ${object.id || '<missing>'} must have one explicit owner and availability boundary`);
  assert.ok(!objects.has(object.id), `runtime object ${object.id} has ambiguous ownership entries`);
  objects.set(object.id, object);
}

for (const [name, ids] of Object.entries(ownership.requirement_sets)) {
  assert.ok(ids.length, `${name} must not be an empty requirement set`);
  assert.equal(new Set(ids).size, ids.length, `${name} must not duplicate runtime objects`);
  for (const id of ids)
    assert.ok(objects.has(id), `${name} references unknown runtime object ${id}`);
}
for (const surface of [...ownership.control_groups, ...ownership.additional_surfaces]) {
  assert.ok(surface.requirements.length, `${surface.id} must declare runtime requirements`);
  for (const requirement of surface.requirements)
    assert.ok(ownership.requirement_sets[requirement], `${surface.id} references unknown requirement set ${requirement}`);
}

const dependencyMatch = builder.match(/write_control \\\n+  "premier-router-core" \\\n+  "([^"]+)"/);
assert.ok(dependencyMatch, 'core dependency declaration must remain statically readable');
const coreDependencies = new Set(dependencyMatch[1].split(',').map(value => value.trim().split(/\s+/)[0]));
const luciOrSetupDependencies = new Set(['luci-base', 'rpcd-mod-file', 'uhttpd', 'cgi-io']);
for (const object of objects.values()) {
  if (object.availability === 'dependency' && !luciOrSetupDependencies.has(object.owner))
    assert.ok(coreDependencies.has(object.package || object.owner),
      `${object.id} owner ${object.package || object.owner} must be a canonical core dependency`);
  if (object.availability === 'conditional')
    assert.ok(ownership.additional_surfaces.some(surface => surface.visibility_guard &&
      surface.requirements.some(name => ownership.requirement_sets[name].includes(object.id))),
    `${object.id} may be optional only behind a documented visibility guard`);
}

for (const required of ['conntrack', 'ca-bundle', 'kmod-nft-tproxy', 'ip-full', 'nftables-json', 'xray-core', 'tailscale'])
  assert.ok(coreDependencies.has(required), `core dependency ${required} is required by a visible control`);

const projectPaths = [...objects.values()].filter(object => ownership.canonical_project_packages.includes(object.owner));
for (const object of projectPaths) {
  assert.ok(object.path, `${object.id} project-owned object must have an exact installed path`);
  const sourceCandidates = [
    path.join(root, 'luci-vpn-ui/files', object.path),
    path.join(root, 'image-overlay', object.path),
    object.path.startsWith('/www/setup/')
      ? path.join(root, 'firstboot-wizard/www', path.basename(object.path))
      : ''
  ].filter(Boolean);
  const sourceExists = (await Promise.all(sourceCandidates.map(async candidate => {
    try { await fs.access(candidate); return true; } catch { return false; }
  }))).some(Boolean);
  assert.ok(sourceExists || builder.includes(object.path.replace(/^\//, '')) || builder.includes(object.path),
    `${object.id} installed path must be represented by the package builder`);
}

for (const token of [
  '/etc/init.d/xray', '/etc/init.d/xray-transparent', 'xray.enabled.enabled',
  'tailscale.@settings[0]', 'nft ', 'ip -4 ', 'conntrack ', '/etc/xray/direct-domains.txt',
  '/etc/xray/direct-ips.txt', '/etc/xray/vpn-ui-device-bypass-macs.txt'
])
  assert.ok(sources.includes(token), `census token ${token} must remain connected to backend source`);

console.log(`Router UI runtime ownership census passed: ${controlIds.length} controls, ${objects.size} owned objects`);
