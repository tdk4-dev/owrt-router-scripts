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

const modalCalls = [];
const helperCalls = [];
const ui = {
	showModal(title, body) {
		modalCalls.push({ title, body });
	},
	hideModal() {}
};
const element = (tag, attrs, children) => ({
	tag,
	attrs: attrs || {},
	children: Array.isArray(children) ? children : [children]
});
const page = new Function(
	'view', 'fs', 'ui', 'dom', 'L', 'E', '_', 'document', 'confirm',
	source
)(
	{ extend: value => value },
	{
		exec: async (command, args) => {
			helperCalls.push({ command, args });
			return {
				stdout: JSON.stringify({
					ok: true,
					reachable: true,
					latency: '8ms',
					route: 'direct'
				})
			};
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
	{ querySelector: () => null },
	() => true
);

function find(node, predicate) {
	if (!node || typeof node !== 'object')
		return null;
	if (predicate(node))
		return node;
	for (const child of node.children || []) {
		const match = find(child, predicate);
		if (match)
			return match;
	}
	return null;
}

const peer = {
	hostname: 'owrt.tdk4',
	ip: '100.64.0.28',
	online: true
};
const peerSection = page.renderPeers({ peers: [peer] });
const pingLink = find(peerSection, node =>
	node.tag === 'a' && node.children.includes('Ping')
);

assert.ok(pingLink, 'rendered peer row must contain a Ping action');
assert.equal(typeof pingLink.attrs.click, 'function', 'Ping action must have a click handler');

let prevented = false;
await pingLink.attrs.click({
	preventDefault() {
		prevented = true;
	}
});

assert.equal(prevented, true, 'Ping action must prevent anchor navigation');
assert.deepEqual(helperCalls, [{
	command: '/usr/sbin/vpn-ui',
	args: ['tailscale-ping', '100.64.0.28']
}]);
assert.equal(modalCalls.length, 2, 'Ping must show progress and result modals');
assert.match(modalCalls[0].body[0].children[0], /Pinging owrt\.tdk4/);
assert.match(modalCalls[1].body[0].children[0], /reachable in 8ms via direct/);

console.log('Tailscale Ping UI click path passed');
