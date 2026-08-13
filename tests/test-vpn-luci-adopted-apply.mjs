import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
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

const rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const vpnUi = path.join(rootDir, 'luci-vpn-ui/files/usr/sbin/vpn-ui');
const overlay = path.join(rootDir, 'luci-vpn-ui/files/usr/libexec/premier-router/xray-overlay.uc');
const fixture = path.join(rootDir, 'tests/fixtures/xray/valera-manual-config.json');
const aclPath = path.join(rootDir, 'luci-vpn-ui/files/usr/share/rpcd/acl.d/luci-app-vpn-ui.json');
const luciSource = await fs.readFile(
	path.join(rootDir, 'luci-vpn-ui/files/www/luci-static/resources/view/network/vpn.js'),
	'utf8'
);
const fakeRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'router-ui-luci-adopted-'));
const overlayMock = path.join(rootDir, 'tests/support/xray-overlay-mock.mjs');
const configPath = path.join(fakeRoot, 'etc/xray/config.json');
const ownershipPath = path.join(fakeRoot, 'etc/premier-router/xray-ownership.json');
const domainsPath = path.join(fakeRoot, 'etc/xray/direct-domains.txt');
const ipsPath = path.join(fakeRoot, 'etc/xray/direct-ips.txt');
const restartLog = path.join(fakeRoot, 'tmp/xray-restarts');
const transactionId = '20260810T130000Z-abcdef0123456789';
const transactionRoot = path.join(fakeRoot, 'root/premier-router-updates');
let faultBoundary = '';

const sha256 = async file => crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex');
const writeExecutable = async (file, contents) => {
	await fs.writeFile(file, contents, { mode: 0o755 });
	await fs.chmod(file, 0o755);
};

try {
	await Promise.all([
		fs.mkdir(path.join(fakeRoot, 'etc/xray'), { recursive: true }),
		fs.mkdir(path.join(fakeRoot, 'etc/xray/vless-profiles.d'), { recursive: true }),
		fs.mkdir(path.join(fakeRoot, 'etc/premier-router'), { recursive: true }),
		fs.mkdir(path.join(fakeRoot, 'etc/init.d'), { recursive: true }),
		fs.mkdir(path.join(fakeRoot, 'tmp'), { recursive: true }),
		fs.mkdir(path.join(transactionRoot, transactionId), { recursive: true })
	]);
	const valeraConfig = JSON.parse(await fs.readFile(fixture, 'utf8'));
	valeraConfig.routing.rules = [
		{
			type: 'field',
			inboundTag: ['socks-in', 'transparent-in'],
			ip: [
				'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
				'169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
				'224.0.0.0/4', '240.0.0.0/4', '198.51.100.200/32'
			],
			outboundTag: 'direct'
		},
		valeraConfig.routing.rules[1],
		valeraConfig.routing.rules[0],
		valeraConfig.routing.rules[2]
	];
	await fs.writeFile(configPath, `${JSON.stringify(valeraConfig, null, 2)}\n`);
	const profile = values => Object.entries(values)
		.map(([key, value]) => `${key}='${String(value).replaceAll("'", "'\\''")}'`)
		.join('\n') + '\n';
	await fs.writeFile(path.join(fakeRoot, 'etc/xray/vless-profiles.d/current.conf'), profile({
		P_ID: 'current', P_NAME: 'Current', P_URL: '',
		P_UUID: '00000000-0000-4000-8000-000000000006', P_HOST: '198.51.100.200',
		P_PORT: '443', P_VPS_IP: '198.51.100.200', P_NETWORK: 'tcp', P_SECURITY: 'reality',
		P_FLOW: 'xtls-rprx-vision', P_PUBLIC_KEY: 'sanitized-public-key',
		P_SHORT_ID: '0123456789abcdef', P_SNI: 'example.invalid', P_FINGERPRINT: 'chrome',
		P_SPIDERX: '/', P_SOURCE_ID: ''
	}), { mode: 0o600 });
	await fs.writeFile(path.join(fakeRoot, 'etc/xray/vless-profiles.d/alternate.conf'), profile({
		P_ID: 'alternate', P_NAME: 'Alternate', P_URL: '',
		P_UUID: '00000000-0000-4000-8000-000000000007', P_HOST: '198.51.100.201',
		P_PORT: '8443', P_VPS_IP: '198.51.100.201', P_NETWORK: 'tcp', P_SECURITY: 'reality',
		P_FLOW: '', P_PUBLIC_KEY: 'next-sanitized-public-key',
		P_SHORT_ID: 'fedcba9876543210', P_SNI: 'next.example.invalid', P_FINGERPRINT: 'firefox',
		P_SPIDERX: '/next', P_SOURCE_ID: ''
	}), { mode: 0o600 });
	await fs.writeFile(path.join(fakeRoot, 'etc/xray/vless-selected'), 'current\n', { mode: 0o600 });
	await fs.writeFile(path.join(transactionRoot, 'active-transaction'), `${transactionId}\n`);
	await fs.writeFile(
		path.join(transactionRoot, transactionId, 'state.json'),
		'{"state":"committed"}\n'
	);

	const fakeXray = path.join(fakeRoot, 'xray');
	const fakeUcode = path.join(fakeRoot, 'ucode');
	await writeExecutable(fakeUcode, `#!/bin/sh
exec ${JSON.stringify(process.execPath)} ${JSON.stringify(overlayMock)} "$@"
`);
	await writeExecutable(fakeXray, `#!/bin/sh
[ "$1" = run ] && [ "$2" = -test ] && [ "$3" = -config ] && jq -e . "$4" >/dev/null 2>&1
`);
	await writeExecutable(path.join(fakeRoot, 'etc/init.d/xray'), `#!/bin/sh
# Active configuration: /etc/xray/config.json
case "\${1:-}" in
  running) exit 0 ;;
  restart) printf 'restart\\n' >> "$VPN_UI_ROOT_PREFIX/tmp/xray-restarts"; exit 0 ;;
  stop|start) exit 0 ;;
  *) exit 1 ;;
esac
`);
	await writeExecutable(path.join(fakeRoot, 'etc/init.d/xray-transparent'), `#!/bin/sh
FIN0_IP="198.51.100.200"
case "\${1:-}" in running|restart|stop|start) exit 0 ;; *) exit 1 ;; esac
`);

	const acl = JSON.parse(await fs.readFile(aclPath, 'utf8'))['luci-app-vpn-ui'];
	assert.deepEqual(acl.write.file['/usr/sbin/vpn-ui'], ['exec']);
	assert.deepEqual(acl.write.ubus.file, ['exec']);

	const backend = args => {
		const result = spawnSync('/bin/sh', [vpnUi, ...args], {
			encoding: 'utf8',
			env: {
				...process.env,
				PREMIER_ROUTER_HOST_TEST: '1',
				VPN_UI_ROOT_PREFIX: fakeRoot,
				VPN_UI_TEST_ACTIVE_XRAY_CONFIG: '/etc/xray/config.json',
				VPN_UI_XRAY_BIN: fakeXray,
				VPN_UI_XRAY_OVERLAY_HELPER: overlay,
				VPN_UI_UCODE_BIN: fakeUcode,
				VPN_UI_UPDATE_PERSIST_ROOT: transactionRoot,
				VPN_UI_TEST_TAILSCALE_SNAPSHOT:
					'pid=606;enabled=true;backend=Running;ip4=100.64.0.6;routes=unchanged',
				VPN_UI_TEST_ADOPT_FREE_BYTES: '10485760',
				VPN_UI_TEST_ADOPT_FAIL_AFTER: faultBoundary
			}
		});
		assert.equal(result.status, 0, result.stderr || `vpn-ui exited ${result.status}`);
		assert.ok(result.stdout.trim(), 'vpn-ui must return an RPC payload');
		return result;
	};

	const preview = JSON.parse(backend(['adoption-preview']).stdout);
	assert.equal(preview.ok, true);
	assert.equal(preview.adoption.analysis.domain_count, 166);
	assert.equal(preview.adoption.analysis.ip_count, 14);
	assert.equal(preview.adoption.analysis.domain_rule_index, 2);
	assert.equal(preview.adoption.analysis.ip_rule_index, 1);
	const adopted = JSON.parse(backend([
		'adoption-confirm',
		preview.adoption.path,
		preview.adoption.config_sha256,
		String(preview.adoption.analysis.domain_rule_index),
		String(preview.adoption.analysis.ip_rule_index)
	]).stdout);
	assert.equal(adopted.ok, true);

	const textareas = {
		'#vpn-direct-domains': { value: 'full:one.rc8.invalid\ndomain:two.rc8.invalid' },
		'#vpn-direct-ips': { value: '198.51.100.0/25' }
	};
	const helperCalls = [];
	const notifications = [];
	const ui = {
		showModal() {},
		hideModal() {},
		addNotification() {},
		createHandlerFn: (self, name, ...args) => self[name].bind(self, ...args)
	};
	const element = (tag, attrs, children) => ({
		tag,
		attrs: attrs || {},
		children: Array.isArray(children) ? children : [children]
	});
	const findElement = (node, predicate) => {
		if (!node || typeof node !== 'object')
			return null;
		if (predicate(node))
			return node;
		for (const child of node.children || []) {
			const match = findElement(child, predicate);
			if (match)
				return match;
		}
		return null;
	};
	const page = new Function(
		'view', 'fs', 'ui', 'dom', 'L', 'E', '_', 'document', 'confirm',
		luciSource
	)(
		{ extend: value => value },
		{
			exec: async (command, args) => {
				helperCalls.push({ command, args: [...args] });
				assert.equal(command, '/usr/sbin/vpn-ui');
				assert.deepEqual(acl.write.file[command], ['exec']);
				return { stdout: backend(args).stdout };
			}
		},
		ui,
		{ content() {} },
		{
			hasViewPermission: () => true,
			bind: (fn, self, ...args) => fn.bind(self, ...args)
		},
		element,
		value => value,
		{
			querySelector: selector => textareas[selector] || null,
			querySelectorAll: () => []
		},
		() => true
	);
	page.refresh = data => { page.data = data; };
	page.notify = message => { notifications.push(String(message)); };
	page.adoptionPreview = {
		path: '/etc/xray/config.json',
		config_sha256: 'a'.repeat(64),
		domain_sha256: 'b'.repeat(64),
		ip_sha256: 'c'.repeat(64),
		analysis: { domain_count: 166, ip_count: 14, warnings: [] }
	};
	const renderedAdoption = page.renderOwnership({
		ownership: {
			adoption_required: true,
			adopted: false,
			healthy: false,
			mutations_allowed: true
		}
	});
	const adoptButton = findElement(renderedAdoption, node =>
		node.tag === 'button' && (node.children || []).includes('Adopt without rewrite'));
	assert.ok(adoptButton, 'Adopt without rewrite button must be rendered after preview');
	assert.equal(adoptButton.attrs.disabled, null, 'Adopt without rewrite must be enabled');
	page.adoptionPreview = null;

	const adoptedStatus = JSON.parse(backend(['status']).stdout);
	assert.equal(adoptedStatus.ownership.adopted, true);
	assert.equal(adoptedStatus.ownership.healthy, true);
	assert.equal(adoptedStatus.ownership.mutations_allowed, true);
	const assertEnabled = (tree, predicate, message) => {
		const control = findElement(tree, predicate);
		assert.ok(control, `${message} must be rendered`);
		assert.equal(control.attrs.disabled, null, `${message} must be enabled after healthy adoption`);
	};
	assertEnabled(page.renderGlobal(adoptedStatus), node =>
		node.tag === 'button' && (node.children || []).some(value => value === 'Enable' || value === 'Disable'),
		'Global VPN control');
	const renderedProfiles = page.renderProfiles(adoptedStatus);
	assertEnabled(renderedProfiles, node => node.attrs && node.attrs.id === 'vpn-vless-url', 'VLESS input');
	assertEnabled(renderedProfiles, node =>
		node.tag === 'button' && (node.children || []).includes('Add'), 'Profile Add');
	assertEnabled(renderedProfiles, node =>
		node.tag === 'button' && (node.children || []).includes('Refresh pings'), 'Refresh pings');
	assertEnabled(renderedProfiles, node =>
		node.tag === 'button' && (node.children || []).includes('Use'), 'Profile Use');
	const renderedSubscriptions = page.renderSubscriptions(adoptedStatus);
	assertEnabled(renderedSubscriptions, node => node.attrs && node.attrs.id === 'vpn-subscription-url',
		'Subscription input');
	assertEnabled(renderedSubscriptions, node =>
		node.tag === 'button' && (node.children || []).includes('Import'), 'Subscription Import');
	assertEnabled(page.renderAutoSwitch(adoptedStatus), node =>
		node.tag === 'button' && (node.children || []).includes('Apply switching settings'),
		'Automatic switching');
	assertEnabled(page.renderDevices({
		...adoptedStatus,
		devices: [{ hostname: 'fixture', ip: '192.0.2.6', mac: '02:00:00:00:00:06', vpn_disabled: false }]
	}), node => node.tag === 'button' && (node.children || []).includes('Disable'), 'Device VPN control');

	const selectResult = JSON.parse(backend(['select', 'alternate']).stdout);
	assert.equal(selectResult.ok, true);
	assert.equal((await fs.readFile(path.join(fakeRoot, 'etc/xray/vless-selected'), 'utf8')).trim(), 'alternate');
	let selectedConfig = JSON.parse(await fs.readFile(configPath, 'utf8'));
	assert.equal(selectedConfig.outbounds[0].settings.vnext[0].address, '198.51.100.201');
	assert.equal(selectedConfig.outbounds[0].settings.vnext[0].port, 8443);
	assert.equal(selectedConfig.routing.rules[0].ip[9], '198.51.100.201/32');
	assert.equal(selectedConfig.routing.rules.length, 4);
	assert.equal(selectedConfig.inbounds.length, 2);
	assert.match(await fs.readFile(path.join(fakeRoot, 'etc/init.d/xray-transparent'), 'utf8'),
		/FIN0_IP="198\.51\.100\.201"/);
	assert.equal(JSON.parse(backend(['select', 'current']).stdout).ok, true);
	const exactProfilePreimage = {
		config: await sha256(configPath),
		selected: await sha256(path.join(fakeRoot, 'etc/xray/vless-selected')),
		ownership: await sha256(ownershipPath),
		transparent: await sha256(path.join(fakeRoot, 'etc/init.d/xray-transparent'))
	};
	faultBoundary = 'after-restart';
	const failedSelect = JSON.parse(backend(['select', 'alternate']).stdout);
	faultBoundary = '';
	assert.equal(failedSelect.ok, false);
	assert.match(failedSelect.error, /exact Xray configuration, route lists, and management state restored/);
	assert.deepEqual({
		config: await sha256(configPath),
		selected: await sha256(path.join(fakeRoot, 'etc/xray/vless-selected')),
		ownership: await sha256(ownershipPath),
		transparent: await sha256(path.join(fakeRoot, 'etc/init.d/xray-transparent'))
	}, exactProfilePreimage);

	const renderedRules = page.renderRules(adoptedStatus);
	for (const id of ['vpn-direct-domains', 'vpn-direct-ips']) {
		const textarea = findElement(renderedRules, node => node.attrs && node.attrs.id === id);
		assert.ok(textarea, `${id} must be rendered`);
		assert.equal(textarea.attrs.disabled, null, `${id} must be editable after healthy adoption`);
	}
	const applyRules = findElement(renderedRules, node =>
		node.tag === 'button' && (node.children || []).includes('Apply rules'));
	assert.ok(applyRules, 'Apply rules button must be rendered');
	assert.equal(applyRules.attrs.disabled, null, 'Apply rules must be enabled after healthy adoption');

	await page.handleApplyRules();
	assert.deepEqual(helperCalls.at(-1), {
		command: '/usr/sbin/vpn-ui',
		args: ['apply-rules', 'full:one.rc8.invalid\ndomain:two.rc8.invalid', '198.51.100.0/25']
	});
	let config = JSON.parse(await fs.readFile(configPath, 'utf8'));
	assert.deepEqual(config.routing.rules[2].domain, [
		'full:one.rc8.invalid',
		'domain:two.rc8.invalid'
	]);
	assert.deepEqual(config.routing.rules[1].ip, ['198.51.100.0/25']);
	assert.equal(config.routing.domainStrategy, 'AsIs');
	assert.equal(config.inbounds.length, 2);
	assert.equal(config.routing.rules.length, 4);
	assert.equal(config.routing.rules.some(rule => rule.port === '8080'), false);
	assert.equal(config.routing.rules.some(rule => (rule.protocol || []).includes('bittorrent')), false);

	textareas['#vpn-direct-domains'].value = '';
	textareas['#vpn-direct-ips'].value = '';
	await page.handleApplyRules();
	config = JSON.parse(await fs.readFile(configPath, 'utf8'));
	assert.deepEqual(config.routing.rules[2].domain, []);
	assert.deepEqual(config.routing.rules[1].ip, []);

	const exactPreimage = {
		config: await sha256(configPath),
		domains: await sha256(domainsPath),
		ips: await sha256(ipsPath),
		ownership: await sha256(ownershipPath)
	};
	textareas['#vpn-direct-domains'].value = 'full:must-rollback.rc8.invalid';
	textareas['#vpn-direct-ips'].value = '203.0.113.0/25';
	faultBoundary = 'after-config';
	await page.handleApplyRules();
	faultBoundary = '';
	assert.match(notifications.at(-1), /exact Xray configuration, route lists, and management state restored/);
	assert.deepEqual({
		config: await sha256(configPath),
		domains: await sha256(domainsPath),
		ips: await sha256(ipsPath),
		ownership: await sha256(ownershipPath)
	}, exactPreimage);

	const transactionDirs = (await fs.readdir(path.join(fakeRoot, 'etc/premier-router/xray-transactions'), {
		withFileTypes: true
	})).filter(entry => entry.isDirectory() && entry.name !== 'lock');
	let invariantFiles = 0;
	for (const entry of transactionDirs) {
		const directory = path.join(fakeRoot, 'etc/premier-router/xray-transactions', entry.name);
		for (const name of await fs.readdir(directory)) {
			if (!name.startsWith('tailscale-'))
				continue;
			invariantFiles++;
			assert.equal(
				(await fs.readFile(path.join(directory, name), 'utf8')).trim(),
				'pid=606;enabled=true;backend=Running;ip4=100.64.0.6;routes=unchanged'
			);
		}
	}
	assert.ok(invariantFiles >= 6, 'apply, removal, and rollback must retain Tailscale invariants');
	assert.ok((await fs.readFile(restartLog, 'utf8')).trim().split('\n').length >= 3,
		'Xray must restart after apply/removal and exact rollback');

	console.log('LuCI -> RPC/ACL -> full adopted controls -> profile switch -> rules -> exact rollback passed');
}
finally {
	await fs.rm(fakeRoot, { recursive: true, force: true });
}
