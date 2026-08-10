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
const ucode = process.env.TEST_UCODE_BIN || process.env.UCODE_BIN || 'ucode';
const fakeRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'router-ui-luci-adopted-'));
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
		fs.mkdir(path.join(fakeRoot, 'etc/premier-router'), { recursive: true }),
		fs.mkdir(path.join(fakeRoot, 'etc/init.d'), { recursive: true }),
		fs.mkdir(path.join(fakeRoot, 'tmp'), { recursive: true }),
		fs.mkdir(path.join(transactionRoot, transactionId), { recursive: true })
	]);
	await fs.copyFile(fixture, configPath);
	await fs.writeFile(path.join(transactionRoot, 'active-transaction'), `${transactionId}\n`);
	await fs.writeFile(
		path.join(transactionRoot, transactionId, 'state.json'),
		'{"state":"committed"}\n'
	);

	const fakeXray = path.join(fakeRoot, 'xray');
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
				VPN_UI_UCODE_BIN: ucode,
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
	const adopted = JSON.parse(backend([
		'adoption-confirm',
		preview.adoption.path,
		preview.adoption.config_sha256,
		String(preview.adoption.analysis.domain_rule_index),
		String(preview.adoption.analysis.ip_rule_index)
	]).stdout);
	assert.equal(adopted.ok, true);

	const textareas = {
		'#vpn-direct-domains': { value: 'full:one.rc6.invalid\ndomain:two.rc6.invalid' },
		'#vpn-direct-ips': { value: '198.51.100.0/25' }
	};
	const helperCalls = [];
	const notifications = [];
	const ui = { showModal() {}, hideModal() {}, addNotification() {} };
	const element = (tag, attrs, children) => ({
		tag,
		attrs: attrs || {},
		children: Array.isArray(children) ? children : [children]
	});
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

	await page.handleApplyRules();
	assert.deepEqual(helperCalls.at(-1), {
		command: '/usr/sbin/vpn-ui',
		args: ['apply-rules', 'full:one.rc6.invalid\ndomain:two.rc6.invalid', '198.51.100.0/25']
	});
	let config = JSON.parse(await fs.readFile(configPath, 'utf8'));
	assert.deepEqual(config.routing.rules[0].domain, [
		'full:one.rc6.invalid',
		'domain:two.rc6.invalid'
	]);
	assert.deepEqual(config.routing.rules[1].ip, ['198.51.100.0/25']);
	assert.equal(config.routing.domainStrategy, 'AsIs');
	assert.equal(config.inbounds.length, 2);
	assert.equal(config.routing.rules.length, 3);
	assert.equal(config.routing.rules.some(rule => rule.port === '8080'), false);
	assert.equal(config.routing.rules.some(rule => (rule.protocol || []).includes('bittorrent')), false);

	textareas['#vpn-direct-domains'].value = '';
	textareas['#vpn-direct-ips'].value = '';
	await page.handleApplyRules();
	config = JSON.parse(await fs.readFile(configPath, 'utf8'));
	assert.deepEqual(config.routing.rules[0].domain, []);
	assert.deepEqual(config.routing.rules[1].ip, []);

	const exactPreimage = {
		config: await sha256(configPath),
		domains: await sha256(domainsPath),
		ips: await sha256(ipsPath),
		ownership: await sha256(ownershipPath)
	};
	textareas['#vpn-direct-domains'].value = 'full:must-rollback.rc6.invalid';
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

	console.log('LuCI -> RPC/ACL -> adopted structural apply/removal -> Xray restart -> exact rollback passed');
}
finally {
	await fs.rm(fakeRoot, { recursive: true, force: true });
}
