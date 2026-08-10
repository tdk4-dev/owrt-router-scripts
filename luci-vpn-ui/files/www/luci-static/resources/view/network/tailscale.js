'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var helper = '/usr/sbin/vpn-ui';
var readonlyHelper = '/usr/sbin/vpn-ui-readonly';
var isReadonlyView = !L.hasViewPermission() || null;

var css = '\
.tailscale-ui .ts-state { display:flex; gap:.5rem; flex-wrap:wrap; margin:.5rem 0 1rem; }\
.tailscale-ui .ts-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:1rem; }\
.tailscale-ui .ts-field label { display:block; margin-bottom:.35rem; }\
.tailscale-ui .ts-field input[type="text"], .tailscale-ui .ts-field input[type="password"] { width:100%; box-sizing:border-box; }\
.tailscale-ui .ts-check { display:flex; gap:.5rem; align-items:center; min-height:2.2rem; }\
.tailscale-ui .ts-actions { display:flex; justify-content:flex-end; gap:.5rem; flex-wrap:wrap; margin-top:1rem; }\
.tailscale-ui .ts-note { opacity:.72; margin:.5rem 0 1rem; }\
.tailscale-ui .ts-summary { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:.75rem; margin:1rem 0; }\
.tailscale-ui .ts-summary-card { border:1px solid #444; border-radius:.5rem; padding:.85rem; background:rgba(255,255,255,.025); }\
.tailscale-ui .ts-summary-label { display:block; opacity:.65; font-size:.85em; margin-bottom:.25rem; }\
.tailscale-ui .ts-summary-value { font-size:1.05em; font-weight:700; overflow-wrap:anywhere; }\
.tailscale-ui .ts-table-wrap { overflow-x:auto; }\
.tailscale-ui .ts-peer-online { box-shadow:inset 3px 0 0 #2fb35d; }\
.tailscale-ui .ts-peer-name { font-weight:700; }\
.tailscale-ui .ts-peer-sub { display:block; opacity:.68; font-size:.9em; margin-top:.15rem; }\
';

function parseResponse(res) {
	var data, output = (res && res.stdout) ? res.stdout.trim() : '';

	try {
		data = JSON.parse(output);
	}
	catch (e) {
		throw new Error(output || _('The Tailscale helper returned an unreadable response.'));
	}

	if (!data.ok)
		throw new Error(data.error || _('The Tailscale helper rejected the request.'));

	return data;
}

return view.extend({
	callHelper: function(args) {
		var command = args && args[0];
		var readCommand = command === 'tailscale-status' || command === 'tailscale-ping';

		return fs.exec(readCommand ? readonlyHelper : helper, args).then(parseResponse);
	},

	load: function() {
		return this.callHelper(['tailscale-status']);
	},

	refresh: function(data) {
		this.data = data;
		dom.content(document.querySelector('#tailscale-ui-root'), this.renderBody(data));
	},

	runAction: function(args, title) {
		ui.showModal(title, [
			E('p', { 'class': 'spinning' }, _('Applying changes...'))
		]);

		return this.callHelper(args).then(L.bind(function(data) {
			ui.hideModal();
			this.refresh(data);
			ui.addNotification(null, E('p', {}, _('Tailscale settings updated.')));
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	handleApply: function() {
		var server = document.querySelector('#ts-login-server');
		var hostname = document.querySelector('#ts-hostname');
		var key = document.querySelector('#ts-auth-key');
		var routes = document.querySelector('#ts-routes');
		var exitNode = document.querySelector('#ts-exit-node');

		return this.runAction([
			'tailscale-up',
			server ? server.value.trim() : '',
			hostname ? hostname.value.trim() : '',
			key ? key.value.trim() : '',
			routes ? routes.value.trim() : '',
			exitNode && exitNode.checked ? '1' : '0'
		], _('Applying Tailscale settings'));
	},

	handleRestart: function() {
		return this.runAction(['tailscale-restart'], _('Restarting Tailscale'));
	},

	handleStop: function() {
		return this.runAction(['tailscale-stop'], _('Stopping Tailscale'));
	},

	handleLogout: function() {
		if (!confirm(_('Log this router out of its current tailnet?')))
			return;
		return this.runAction(['tailscale-logout'], _('Logging out of Tailscale'));
	},

	handlePeerPing: function(peer) {
		var title = _('Tailscale ping: %s').format(peer.hostname || peer.ip);

		ui.showModal(title, [
			E('p', { 'class': 'spinning' }, _('Pinging %s…').format(peer.hostname || peer.ip))
		]);

		return this.callHelper(['tailscale-ping', peer.ip]).then(function(data) {
			var message = data.reachable
				? _('%s is reachable in %s via %s.').format(peer.hostname || peer.ip, data.latency || '-', data.route || '-')
				: _('%s did not respond.\n%s').format(peer.hostname || peer.ip, data.output || '');

			ui.showModal(title, [
				E('p', { 'style': 'white-space:pre-wrap; overflow-wrap:anywhere' }, message),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
				])
			]);
		}).catch(function(err) {
			ui.showModal(title, [
				E('p', {}, err.message || err),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('Close'))
				])
			]);
		});
	},

	formatLastSeen: function(value, online) {
		if (online)
			return _('Now');
		if (!value)
			return _('Unknown');
		return value.replace('T', ' ').replace(/(\.[0-9]+)?Z$/, ' UTC');
	},

	renderPeers: function(tailscale) {
		var peers = (tailscale.peers || []).slice().sort(function(a, b) {
			if (!!a.online !== !!b.online)
				return a.online ? -1 : 1;
			return (a.hostname || a.ip).localeCompare(b.hostname || b.ip);
		});
		var rows = peers.map(function(peer) {
			var route = peer.direct_address || (peer.relay ? 'DERP: ' + peer.relay : '-');

			return E('tr', { 'class': 'tr' + (peer.online ? ' ts-peer-online' : '') }, [
				E('td', { 'class': 'td left' }, [
					E('span', { 'class': 'ts-peer-name' }, peer.hostname || peer.dns_name || peer.ip),
					E('span', { 'class': 'ts-peer-sub' }, peer.dns_name && peer.dns_name !== peer.hostname ? peer.dns_name : peer.os || '-')
				]),
				E('td', { 'class': 'td left' }, peer.ip || '-'),
				E('td', { 'class': 'td left' }, [
					E('span', { 'class': 'label ' + (peer.online ? 'notice' : '') }, peer.online ? _('Online') : _('Offline')),
					peer.active ? ' ' : '',
					peer.active ? E('span', { 'class': 'label notice' }, _('Active')) : ''
				]),
				E('td', { 'class': 'td left' }, route),
				E('td', { 'class': 'td left' }, [
					peer.exit_node ? E('span', { 'class': 'label notice' }, _('Selected exit')) :
						(peer.exit_node_option ? E('span', { 'class': 'label' }, _('Exit node')) : '-')
				]),
				E('td', { 'class': 'td left' }, this.formatLastSeen(peer.last_seen, peer.online)),
				E('td', { 'class': 'td right' }, [
					E('a', {
						'class': 'cbi-button cbi-button-action',
						'href': '#',
						'aria-disabled': peer.ip ? 'false' : 'true',
						'click': L.bind(function(ev) {
							ev.preventDefault();
							if (peer.ip)
								return this.handlePeerPing(peer);
						}, this)
					}, _('Ping'))
				])
			]);
		}, this);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Tailnet devices')),
			E('p', { 'class': 'ts-note' }, _('%d devices visible, %d online. Ping uses the Tailscale data path and reports direct or DERP routing.')
				.format(peers.length, peers.filter(function(peer) { return peer.online; }).length)),
			E('div', { 'class': 'ts-table-wrap' }, [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th left' }, _('Device')),
						E('th', { 'class': 'th left' }, _('Tailscale IP')),
						E('th', { 'class': 'th left' }, _('Status')),
						E('th', { 'class': 'th left' }, _('Path')),
						E('th', { 'class': 'th left' }, _('Routing')),
						E('th', { 'class': 'th left' }, _('Last seen')),
						E('th', { 'class': 'th right' }, '')
					])
				].concat(rows.length ? rows : [
					E('tr', { 'class': 'tr placeholder' }, [
						E('td', { 'class': 'td', 'colspan': '7' }, _('No tailnet peers are visible.'))
					])
				]))
			])
		]);
	},

	renderBody: function(data) {
		var tailscale = data.tailscale || {};

		return [
		E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'ts-state' }, [
				E('span', { 'class': 'label ' + (tailscale.connected ? 'notice' : 'warning') },
					tailscale.connected ? _('Connected') : _('Disconnected')),
				E('span', { 'class': 'label' }, _('Service: %s').format(tailscale.running ? _('running') : _('stopped'))),
				E('span', { 'class': 'label' }, 'IP: %s'.format(tailscale.ip || '-')),
				E('span', { 'class': 'label' }, 'Control: %s'.format(tailscale.control_url || '-'))
			]),
			E('div', { 'class': 'ts-summary' }, [
				E('div', { 'class': 'ts-summary-card' }, [
					E('span', { 'class': 'ts-summary-label' }, _('Tailnet')),
					E('span', { 'class': 'ts-summary-value' }, tailscale.tailnet || '-')
				]),
				E('div', { 'class': 'ts-summary-card' }, [
					E('span', { 'class': 'ts-summary-label' }, _('Tailscale version')),
					E('span', { 'class': 'ts-summary-value' }, tailscale.version || '-')
				]),
				E('div', { 'class': 'ts-summary-card' }, [
					E('span', { 'class': 'ts-summary-label' }, _('Visible devices')),
					E('span', { 'class': 'ts-summary-value' }, String((tailscale.peers || []).length))
				]),
				E('div', { 'class': 'ts-summary-card' }, [
					E('span', { 'class': 'ts-summary-label' }, _('Online devices')),
					E('span', { 'class': 'ts-summary-value' }, String((tailscale.peers || []).filter(function(peer) { return peer.online; }).length))
				])
			]),
			E('p', { 'class': 'ts-note' }, _('Preauth keys are passed directly to Tailscale and are not stored by this panel.')),
			E('div', { 'class': 'ts-grid' }, [
				E('div', { 'class': 'ts-field' }, [
					E('label', { 'for': 'ts-login-server' }, _('Login server')),
					E('input', {
						'id': 'ts-login-server',
						'type': 'text',
						'value': tailscale.control_url || 'https://login.tailscale.com',
						'disabled': isReadonlyView
					})
				]),
				E('div', { 'class': 'ts-field' }, [
					E('label', { 'for': 'ts-hostname' }, _('Node hostname')),
					E('input', {
						'id': 'ts-hostname',
						'type': 'text',
						'value': tailscale.hostname || '',
						'disabled': isReadonlyView
					})
				]),
				E('div', { 'class': 'ts-field' }, [
					E('label', { 'for': 'ts-auth-key' }, _('Preauth key')),
					E('input', {
						'id': 'ts-auth-key',
						'type': 'password',
						'autocomplete': 'off',
						'placeholder': tailscale.connected ? _('Optional while connected') : _('Required for first login'),
						'disabled': isReadonlyView
					})
				]),
				E('div', { 'class': 'ts-field' }, [
					E('label', { 'for': 'ts-routes' }, _('Advertise routes')),
					E('input', {
						'id': 'ts-routes',
						'type': 'text',
						'placeholder': '10.77.0.0/24',
						'disabled': isReadonlyView
					})
				]),
				E('label', { 'class': 'ts-check' }, [
					E('input', {
						'id': 'ts-exit-node',
						'type': 'checkbox',
						'disabled': isReadonlyView
					}),
					_('Advertise this router as an exit node')
				])
			]),
			E('div', { 'class': 'ts-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleRestart')
				}, _('Restart')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': isReadonlyView || !tailscale.running,
					'click': ui.createHandlerFn(this, 'handleStop')
				}, _('Stop service')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': isReadonlyView || !tailscale.connected,
					'click': ui.createHandlerFn(this, 'handleLogout')
				}, _('Log out')),
				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleApply')
				}, _('Apply / connect'))
			])
		]),
		this.renderPeers(tailscale)
		];
	},

	render: function(data) {
		this.data = data;

		return E('div', { 'class': 'cbi-map tailscale-ui' }, [
			E('style', {}, css),
			E('h2', {}, _('Tailscale / Headscale')),
			E('div', { 'id': 'tailscale-ui-root' }, this.renderBody(data))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
