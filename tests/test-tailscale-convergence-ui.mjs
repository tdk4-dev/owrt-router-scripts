import assert from 'node:assert/strict';
import fs from 'node:fs/promises';

if (!String.prototype.format) {
	Object.defineProperty(String.prototype, 'format', {
		value: function(...args) {
			let index = 0;
			return this.replace(/%[sd]/g, () => String(args[index++]));
		}
	});
}

const source = await fs.readFile(
	new URL('../luci-vpn-ui/files/www/luci-static/resources/view/network/tailscale.js', import.meta.url),
	'utf8'
);
const element = (tag, attrs, children) => ({
	tag,
	attrs: attrs || {},
	children: Array.isArray(children) ? children : [children]
});

function makePage(responder) {
	const calls = [];
	const events = [];
	const ui = {
		showModal() { events.push('modal-shown'); },
		hideModal() { events.push('modal-hidden'); },
		addNotification(_title, body) { events.push(`notification:${JSON.stringify(body)}`); },
		createHandlerFn: (self, name, ...args) => self[name].bind(self, ...args)
	};
	const page = new Function(
		'view', 'fs', 'ui', 'dom', 'L', 'E', '_', 'document', 'confirm', 'window',
		source
	)(
		{ extend: value => value },
		{ exec: async (command, args) => {
			calls.push({ command, args });
			return { stdout: JSON.stringify(await responder(command, args, calls, events)) };
		} },
		ui,
		{ content() {} },
		{ hasViewPermission: () => true, bind: (fn, self, ...args) => fn.bind(self, ...args) },
		element,
		value => value,
		{ querySelector: () => null },
		() => true,
		{ setTimeout(fn) { fn(); } }
	);
	return { page, calls, events };
}

const cases = [
	{
		args: ['tailscale-stop'],
		message: 'Tailscale stopped.',
		predicate: state => state.running === false && state.boot_enabled === false,
		pending: { running: true, boot_enabled: true, backend_state: 'Running', connected: true },
		done: { running: false, boot_enabled: false, backend_state: '', connected: false }
	},
	{
		args: ['tailscale-restart'],
		message: 'Tailscale restarted.',
		predicate: state => state.running === true && state.backend_state === 'Running',
		pending: { running: true, boot_enabled: true, backend_state: 'Starting', connected: false },
		done: { running: true, boot_enabled: true, backend_state: 'Running', connected: true }
	},
	{
		args: ['tailscale-up'],
		message: 'Tailscale settings applied.',
		predicate: state => state.running === true && state.boot_enabled === true &&
			state.backend_state === 'Running' && state.connected === true,
		pending: { running: true, boot_enabled: true, backend_state: 'Starting', connected: false },
		done: { running: true, boot_enabled: true, backend_state: 'Running', connected: true }
	},
	{
		args: ['tailscale-logout'],
		message: 'Tailscale logged out.',
		predicate: state => state.backend_state === 'NeedsLogin' && state.connected === false,
		pending: { running: true, boot_enabled: true, backend_state: 'Running', connected: true },
		done: { running: true, boot_enabled: true, backend_state: 'NeedsLogin', connected: false }
	}
];

for (const testCase of cases) {
	let reads = 0;
	const { page, calls, events } = makePage(async (_command, args) => {
		if (args[0] !== 'tailscale-status')
			return { ok: true, tailscale: testCase.pending };
		reads++;
		return { ok: true, tailscale: reads < 3 ? testCase.pending : testCase.done };
	});
	await page.runAction(testCase.args, 'fixture', testCase.predicate, testCase.message);
	assert.equal(reads, 3, `${testCase.args[0]} must wait for fresh read-only convergence`);
	assert.deepEqual(calls[0], { command: '/usr/sbin/vpn-ui', args: testCase.args });
	for (const call of calls.slice(1))
		assert.deepEqual(call, { command: '/usr/sbin/vpn-ui-readonly', args: ['tailscale-status'] });
	assert.equal(events.at(-2), 'modal-hidden');
	assert.match(events.at(-1), new RegExp(testCase.message.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
}

{
	const { page, calls, events } = makePage(async () => ({ ok: false, error: 'restart failed and state restored' }));
	await page.runAction(
		['tailscale-restart'],
		'fixture',
		state => state.running === true && state.backend_state === 'Running',
		'Tailscale restarted.'
	);
	assert.equal(calls.length, 1, 'backend failure must not begin browser success polling');
	assert.doesNotMatch(events.at(-1), /Tailscale restarted\./);
	assert.match(events.at(-1), /restart failed and state restored/);
}

{
	const pending = { running: true, boot_enabled: true, backend_state: 'Starting', connected: false };
	const { page, calls, events } = makePage(async (_command, args) => ({
		ok: true,
		tailscale: pending
	}));
	await page.runAction(
		['tailscale-restart'],
		'fixture',
		state => state.running === true && state.backend_state === 'Running',
		'Tailscale restarted.'
	);
	assert.equal(calls.length, 61, 'browser convergence timeout must be bounded');
	assert.doesNotMatch(events.at(-1), /Tailscale restarted\./);
	assert.match(events.at(-1), /did not converge/);
}

console.log('Tailscale browser postcondition polling, specific success, failure, and timeout checks passed');
