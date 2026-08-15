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
	new URL('../luci-vpn-ui/files/www/luci-static/resources/view/system/update.js', import.meta.url),
	'utf8'
);
const element = (tag, attrs, children) => ({
	tag,
	attrs: attrs || {},
	children: Array.isArray(children) ? children : [children]
});

function makePage(responder) {
	const calls = [];
	const notifications = [];
	const ui = {
		showModal() {},
		hideModal() {},
		addNotification(_title, body) { notifications.push(body); }
	};
	const page = new Function(
		'view', 'fs', 'ui', 'dom', 'L', 'E', '_', 'document', 'confirm', 'window',
		source
	)(
		{ extend: value => value },
		{ exec: async (command, args) => {
			calls.push({ command, args });
			return { stdout: JSON.stringify(await responder(command, args, calls)) };
		} },
		ui,
		{ content() {} },
		{ hasViewPermission: () => true, bind: (fn, self, ...args) => fn.bind(self, ...args) },
		element,
		value => value,
		{ querySelector: () => null },
		() => true,
		{ setTimeout(fn) { fn(); }, location: { reload() {} } }
	);
	return { page, calls, notifications };
}

const idA = 'a'.repeat(64);
const idB = 'b'.repeat(64);
const oldId = 'c'.repeat(64);

{
	let exactPolls = 0;
	const { page, calls, notifications } = makePage(async (_command, args) => {
		switch (args[0]) {
		case 'update-check-start':
			return { ok: true, job: { id: idA, kind: 'check', status: 'running' } };
		case 'update-job-status':
			exactPolls++;
			return { ok: true, job: {
				id: idA, kind: 'check', status: exactPolls < 3 ? 'running' : 'succeeded',
				checked_at: exactPolls < 3 ? '' : '2026-08-15T10:00:00Z'
			} };
		case 'update-status':
			return {
				ok: true, current: '0.7.11-rc.13', latest: '0.7.11', checked_at: '2026-08-15T10:00:00Z',
				job: { id: oldId, status: 'success', stage: 'committed' }
			};
		default: throw new Error(`unexpected command ${args[0]}`);
		}
	});
	await page.startJob('check');
	assert.equal(exactPolls, 3, 'fresh Check must remain pending until its exact job succeeds');
	assert.deepEqual(calls.slice(1, 4).map(call => call.args), [
		['update-job-status', idA, 'check'],
		['update-job-status', idA, 'check'],
		['update-job-status', idA, 'check']
	]);
	assert.equal(calls.at(-1).args[0], 'update-status', 'generic rendering refresh must happen only after exact completion');
	assert.equal(notifications.length, 0, 'old committed journal must not create a fresh Check notification');
}

{
	let genericReads = 0;
	const { page, calls, notifications } = makePage(async (_command, args) => {
		if (args[0] === 'update-check-start')
			return { ok: true, job: { id: idB, kind: 'check', status: 'running' } };
		if (args[0] === 'update-job-status')
			return { ok: true, job: { id: idB, kind: 'check', status: 'failed', message: 'fresh discovery failed' } };
		if (args[0] === 'update-status') {
			genericReads++;
			return { ok: true, job: { id: oldId, status: 'success', stage: 'committed' } };
		}
		throw new Error(`unexpected command ${args[0]}`);
	});
	await page.startJob('check');
	assert.equal(genericReads, 0, 'failed exact Check must never fall back to old generic success');
	assert.deepEqual(calls.map(call => call.args), [
		['update-check-start'],
		['update-job-status', idB, 'check']
	]);
	assert.match(JSON.stringify(notifications), /fresh discovery failed/);
}

{
	const { page, calls, notifications } = makePage(async (_command, args) => {
		if (args[0] === 'update-check-start')
			return { ok: true, job: { id: idA, kind: 'apply', status: 'running' } };
		throw new Error('wrong-kind start must not be polled');
	});
	await page.startJob('check');
	assert.equal(calls.length, 1);
	assert.match(JSON.stringify(notifications), /valid operation identity/);
}

{
	const { page, calls, notifications } = makePage(async (_command, args) => {
		if (args[0] === 'update-check-start')
			return { ok: true, job: { id: idA, kind: 'check', status: 'running' } };
		return { ok: false, error_code: 'unknown_job_id', error: 'operation missing' };
	});
	await page.startJob('check');
	assert.equal(calls.length, 2, 'unknown exact job must fail closed without retrying generic status');
	assert.match(JSON.stringify(notifications), /operation missing/);
}

{
	const ids = [idA, idB];
	const completed = [];
	const { page } = makePage(async (_command, args) => {
		if (args[0] === 'update-check-start') {
			const id = ids.shift();
			return { ok: true, job: { id, kind: 'check', status: 'running' } };
		}
		if (args[0] === 'update-job-status') {
			completed.push(args[1]);
			return { ok: true, job: { id: args[1], kind: 'check', status: 'succeeded' } };
		}
		return { ok: true, current: '0.7.11-rc.13', job: { status: 'success' } };
	});
	await page.startJob('check');
	await page.startJob('check');
	assert.deepEqual(completed, [idA, idB], 'sequential Checks must poll their own unique identities');
}

{
	const { page, calls, notifications } = makePage(async (_command, args) => {
		if (args[0] === 'update-apply-start')
			return { ok: true, job: { id: idA, kind: 'apply', status: 'running' } };
		if (args[0] === 'update-job-status')
			return { ok: true, job: { id: idA, kind: 'apply', status: 'pending_reboot', transaction_id: 'tx-1' } };
		return { ok: true, current: '0.7.11-rc.14', job: { status: 'pending_reboot' } };
	});
	await page.startJob('apply');
	assert.deepEqual(calls.map(call => call.args), [
		['update-apply-start'],
		['update-job-status', idA, 'apply'],
		['update-status']
	]);
	assert.match(JSON.stringify(notifications), /Reboot is required/);
	assert.doesNotMatch(JSON.stringify(notifications), /installed and validated/);
}

console.log('Update browser exact-operation correlation and stale-journal isolation checks passed');
