import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function(...args) {
			let index = 0;
			return this.replace(/%[sd]/g, () => String(args[index++]));
		}
	});
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = {
	update: 'luci-vpn-ui/files/www/luci-static/resources/view/system/update.js',
	vpn: 'luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js',
	tailscale: 'luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js'
};
const sources = Object.fromEntries(await Promise.all(Object.entries(files).map(async ([name, file]) =>
	[name, await fs.readFile(path.join(root, file), 'utf8')]
)));
const acl = JSON.parse(await fs.readFile(
	path.join(root, 'luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json'), 'utf8'
))['luci-app-vpn-ui'];
const unexpectedConsoleErrors = [];
const originalConsoleError = console.error;
console.error = (...args) => unexpectedConsoleErrors.push(args.map(String).join(' '));

const element = (tag, attrs, children) => {
	const normalizedAttrs = Object.fromEntries(Object.entries(attrs || {})
		.filter(([, value]) => value !== null && value !== undefined));
	return {
		tag,
		attrs: normalizedAttrs,
		children: Array.isArray(children) ? children : [children],
		getAttribute(name) {
			if (!Object.hasOwn(this.attrs, name))
				return null;
			return this.attrs[name] === true ? '' : String(this.attrs[name]);
		},
		get disabled() {
			return Object.hasOwn(this.attrs, 'disabled');
		}
	};
};
const walk = function*(node) {
	if (!node || typeof node !== 'object')
		return;
	yield node;
	for (const child of node.children || [])
		yield* walk(child);
};
const controls = tree => {
	const result = new Map();
	const roots = Array.isArray(tree) ? tree : [tree];
	for (const rootNode of roots) {
		for (const node of walk(rootNode)) {
			const id = node.attrs?.['data-control-id'];
			if (id && !result.has(id))
				result.set(id, node);
		}
	}
	return result;
};
const blocked = node => node.getAttribute('disabled') !== null ||
	node.attrs['aria-disabled'] === 'true';
const interactable = node => !blocked(node) && typeof node.attrs.click === 'function';
const dispatchControl = async node => {
	if (blocked(node))
		return false;
	await node.attrs.click({ preventDefault() {} });
	return true;
};

function makePage(viewName, permission, execImpl = async () => ({ stdout: '{"ok":true}' })) {
	const modals = [];
	const notifications = [];
	const ui = {
		showModal: (title, body) => modals.push({ title, body }),
		hideModal() {},
		addNotification: (_title, body) => notifications.push(body),
		createHandlerFn: (self, name, ...args) => self[name].bind(self, ...args)
	};
	const document = {
		querySelector: () => null,
		querySelectorAll: () => []
	};
	const page = new Function(
		'view', 'fs', 'ui', 'dom', 'L', 'E', '_', 'document', 'confirm', 'window',
		sources[viewName]
	)(
		{ extend: value => value },
		{ exec: execImpl },
		ui,
		{ content() {} },
		{ hasViewPermission: () => permission, bind: (fn, self, ...args) => fn.bind(self, ...args) },
		element,
		value => value,
		document,
		() => true,
		{ setTimeout() {}, location: { reload() {} } }
	);
	return { page, modals, notifications, document };
}

const profile = {
	id: 'profile-1', name: 'Fixture', host: '198.51.100.10', port: 443,
	protocol: 'vless', vps_ip: '198.51.100.10', selected: false, auto_pool: true,
	ping: '8 ms'
};
const subscription = { id: 'sub-1', name: 'Fixture provider', count: 1, updated: 'now' };
const device = {
	hostname: 'fixture', ip: '192.0.2.10', mac: '02:00:00:00:00:10',
	lease_remaining: '1h', vpn_disabled: false
};
const baseVpn = {
	services: { vpn_enabled: true, xray: 'running', transparent: 'active' },
	profiles: [profile], subscriptions: [subscription], devices: [device],
	auto: { failover: true, periodic: true, periodic_hours: 12 },
	domains: ['domain:example.invalid'], ips: ['198.51.100.0/24']
};
const ownershipStates = {
	'native-generated': { adoption_required: false, adopted: false, healthy: true, mutations_allowed: true },
	'empty-unconfigured': { adoption_required: false, adopted: false, healthy: true, mutations_allowed: true },
	'manual-unadopted': { adoption_required: true, adopted: false, healthy: false, mutations_allowed: true },
	'healthy-adopted': { adoption_required: false, adopted: true, healthy: true, mutations_allowed: true },
	'adopted-drift-recovery': { adoption_required: false, adopted: true, healthy: false, mutations_allowed: true },
	'reboot-pending': { adoption_required: false, adopted: true, healthy: true, mutations_allowed: false }
};
const vpnMutationIds = [
	'vpn-global-toggle', 'vpn-profile-url', 'vpn-profile-add', 'vpn-ping-refresh',
	'vpn-profile-auto-pool', 'vpn-profile-use', 'vpn-profile-delete',
	'vpn-subscription-url', 'vpn-subscription-import', 'vpn-subscription-sync',
	'vpn-subscription-delete', 'vpn-auto-failover', 'vpn-auto-periodic',
	'vpn-auto-hours', 'vpn-auto-apply', 'vpn-direct-domains', 'vpn-direct-ips',
	'vpn-direct-apply', 'vpn-device-toggle'
];

for (const [state, ownership] of Object.entries(ownershipStates)) {
	const { page } = makePage('vpn', true);
	const stateData = { ...baseVpn, ownership };
	if (state === 'empty-unconfigured') {
		stateData.profiles = [];
		stateData.subscriptions = [];
		stateData.devices = [];
	}
	let rendered = controls(page.renderBody(stateData));
	for (const id of vpnMutationIds) {
		if (!rendered.has(id))
			continue;
		const shouldBlock = ['manual-unadopted', 'adopted-drift-recovery', 'reboot-pending'].includes(state);
		const control = rendered.get(id);
		assert.equal(blocked(control), shouldBlock, `${state}/${id} blocked state mismatch`);
		assert.equal(control.disabled, shouldBlock, `${state}/${id} native disabled property mismatch`);
		assert.equal(control.getAttribute('disabled') !== null, shouldBlock,
			`${state}/${id} disabled attribute presence mismatch`);
	}
	assert.equal(rendered.has('vpn-adoption-preview'),
		['manual-unadopted', 'adopted-drift-recovery'].includes(state),
		`${state} adoption preview visibility mismatch`);
	if (rendered.has('vpn-adoption-preview'))
		assert.equal(blocked(rendered.get('vpn-adoption-preview')), false);

	page.adoptionPreview = {
		path: '/etc/xray/config.json', config_sha256: 'a'.repeat(64),
		domain_sha256: 'b'.repeat(64), ip_sha256: 'c'.repeat(64),
		analysis: { domain_rule_index: 0, ip_rule_index: 1, warnings: [] }
	};
	rendered = controls(page.renderBody(stateData));
	if (['manual-unadopted', 'adopted-drift-recovery', 'reboot-pending'].includes(state)) {
		assert.ok(rendered.has('vpn-adoption-confirm'));
		assert.equal(blocked(rendered.get('vpn-adoption-confirm')), state === 'reboot-pending');
	}
}

{
	const { page } = makePage('vpn', false);
	page.adoptionPreview = {
		path: '/etc/xray/config.json', config_sha256: 'a'.repeat(64),
		domain_sha256: 'b'.repeat(64), ip_sha256: 'c'.repeat(64), analysis: { warnings: [] }
	};
	const rendered = controls(page.renderBody({
		...baseVpn,
		ownership: { adoption_required: true, adopted: false, healthy: false, mutations_allowed: true }
	}));
	for (const id of vpnMutationIds)
		if (rendered.has(id)) {
			const control = rendered.get(id);
			assert.equal(blocked(control), true, `read-only/${id} must block`);
			assert.equal(control.disabled, true, `read-only/${id} native disabled property must be true`);
			assert.notEqual(control.getAttribute('disabled'), null,
				`read-only/${id} disabled attribute must be present`);
		}
	assert.equal(blocked(rendered.get('vpn-adoption-preview')), false, 'read-only preview remains read-only-safe');
	assert.equal(blocked(rendered.get('vpn-adoption-confirm')), true, 'read-only adoption confirmation must block');
	assert.equal(blocked(rendered.get('vpn-domain-test')), false, 'read-only domain test remains available');
}

const tailscaleData = {
	tailscale: {
		connected: true, running: true, control_url: 'https://login.tailscale.com',
		hostname: 'fixture', peers: [{ hostname: 'peer', ip: '100.64.0.2', online: true }]
	}
};

for (const action of ['tailscale-stop', 'tailscale-logout']) {
	const calls = [];
	const { page } = makePage('tailscale', true, async (command, args) => {
		calls.push({ command, args });
		return { stdout: JSON.stringify({ ok: true, tailscale: { running: true, connected: true } }) };
	});
	assert.equal(tailscaleData.tailscale.running, true, `${action} fixture must start running`);
	assert.equal(tailscaleData.tailscale.connected, true, `${action} fixture must start connected`);
	const rendered = controls(page.renderBody(tailscaleData));
	const control = rendered.get(action);
	assert.equal(control.getAttribute('disabled'), null, `${action} must omit disabled attribute`);
	assert.equal(control.disabled, false, `${action} native disabled property must be false`);
	assert.equal(interactable(control), true, `${action} must be interactable`);
	assert.equal(await dispatchControl(control), true, `${action} must dispatch`);
	assert.deepEqual(calls.at(-1), { command: '/usr/sbin/vpn-ui', args: [action] });
}

for (const permission of [true, false]) {
	const { page } = makePage('tailscale', permission);
	const rendered = controls(page.renderBody(tailscaleData));
	for (const id of [
		'tailscale-login-server', 'tailscale-hostname', 'tailscale-auth-key',
		'tailscale-routes', 'tailscale-exit-node', 'tailscale-restart',
		'tailscale-stop', 'tailscale-logout', 'tailscale-apply'
	]) {
		assert.equal(blocked(rendered.get(id)), !permission, `${id} permission boundary mismatch`);
		assert.equal(rendered.get(id).disabled, !permission, `${id} native disabled property mismatch`);
		assert.equal(rendered.get(id).getAttribute('disabled') !== null, !permission,
			`${id} disabled attribute presence mismatch`);
	}
	assert.equal(blocked(rendered.get('tailscale-peer-ping')), false, 'peer ping is read-only-safe');
}

for (const [name, data] of [
	['stopped', { tailscale: { running: false, connected: true, peers: [] } }],
	['disconnected', { tailscale: { running: true, connected: false, peers: [] } }]
]) {
	const calls = [];
	const { page } = makePage('tailscale', true, async (command, args) => {
		calls.push({ command, args });
		return { stdout: '{"ok":true}' };
	});
	const rendered = controls(page.renderBody(data));
	const id = name === 'stopped' ? 'tailscale-stop' : 'tailscale-logout';
	const control = rendered.get(id);
	assert.notEqual(control.getAttribute('disabled'), null, `${name}/${id} must carry disabled attribute`);
	assert.equal(control.disabled, true, `${name}/${id} native disabled property must be true`);
	assert.equal(await dispatchControl(control), false, `${name}/${id} blocked control must not dispatch`);
	assert.deepEqual(calls, [], `${name}/${id} blocked control must not reach backend`);
}

for (const permission of [true, false]) {
	const calls = [];
	const { page } = makePage('update', permission, async (command, args) => {
		calls.push({ command, args });
		assert.deepEqual(acl[permission ? 'write' : 'read'].file[command], ['exec']);
		return { stdout: JSON.stringify({ ok: true, current: '0.7.11-rc.9' }) };
	});
	const data = {
		current: '0.7.11-rc.9', current_channel: 'candidate', latest: '0.7.11',
		available: true, auto_update: false, job: {}, checked_at: '2026-08-13T09:00:00Z'
	};
	const rendered = controls(page.renderBody(data));
	for (const id of ['update-check', 'update-apply', 'update-auto'])
		assert.equal(blocked(rendered.get(id)), !permission, `${id} permission boundary mismatch`);
	if (permission) {
		const status = await page.callHelper(['update-status']);
		assert.equal(status.current, '0.7.11-rc.9');
		assert.deepEqual(calls.at(-1), { command: '/usr/sbin/vpn-ui-readonly', args: ['update-status'] });
	}
}

assert.deepEqual(acl.read.file['/usr/sbin/vpn-ui-readonly'], ['exec']);
assert.equal(acl.read.file['/usr/sbin/vpn-ui'], undefined);
assert.deepEqual(acl.write.file['/usr/sbin/vpn-ui'], ['exec']);
assert.deepEqual(unexpectedConsoleErrors, [], 'mocked control rendering must emit zero console errors');
console.error = originalConsoleError;

console.log('Router UI seven-state mocked rendering, read/write ACL, and console-error checks passed');
