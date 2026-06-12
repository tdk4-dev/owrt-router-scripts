'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var helper = '/usr/sbin/vpn-ui';
var isReadonlyView = !L.hasViewPermission() || null;

var css = '\
.vpn-ui .vpn-add-row { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; margin:.75rem 0 1rem; }\
.vpn-ui .vpn-add-row input { flex:1 1 36rem; min-width:18rem; }\
.vpn-ui .vpn-profile-row.vpn-selected { background:#173d25 !important; }\
.vpn-ui .vpn-profile-row.vpn-selected > .td { background:transparent !important; }\
.vpn-ui .vpn-profile-row.vpn-selected { box-shadow: inset 3px 0 0 #2fb35d; }\
.vpn-ui .vpn-profile-title { font-weight:700; }\
.vpn-ui .vpn-muted { opacity:.72; font-size:.92em; }\
.vpn-ui .vpn-ping-ok { color:#66d489; font-weight:700; }\
.vpn-ui .vpn-ping-bad { color:#d46a6a; font-weight:700; }\
.vpn-ui .vpn-rules-grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(280px, 1fr)); gap:1rem; }\
.vpn-ui .vpn-rules-grid textarea { width:100%; min-height:18rem; box-sizing:border-box; font-family:monospace; white-space:pre; }\
.vpn-ui .vpn-actions { display:flex; justify-content:flex-end; gap:.5rem; flex-wrap:wrap; margin-top:1rem; }\
.vpn-ui .vpn-service-row { display:flex; gap:.5rem; flex-wrap:wrap; margin:.25rem 0 1rem; }\
';

function parseResponse(res) {
	var data, output = (res && res.stdout) ? res.stdout.trim() : '';

	try {
		data = JSON.parse(output);
	}
	catch (e) {
		throw new Error(output || _('The VPN helper returned an unreadable response.'));
	}

	if (!data.ok)
		throw new Error(data.error || _('The VPN helper rejected the request.'));

	return data;
}

function lines(values) {
	return (values || []).join('\n');
}

return view.extend({
	callHelper: function(args) {
		return fs.exec(helper, args).then(parseResponse);
	},

	refresh: function(data) {
		this.data = data;
		dom.content(document.querySelector('#vpn-ui-root'), this.renderBody(data));
	},

	runAction: function(args, title) {
		ui.showModal(title, [
			E('p', { 'class': 'spinning' }, _('Applying changes...'))
		]);

		return this.callHelper(args).then(L.bind(function(data) {
			ui.hideModal();
			this.refresh(data);
			ui.addNotification(null, E('p', {}, _('VPN settings updated.')));
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	handleRefresh: function() {
		return this.runAction(['status'], _('Refreshing VPN status'));
	},

	handleAdd: function() {
		var input = document.querySelector('#vpn-vless-url');
		var value = input ? input.value.trim() : '';

		if (!value) {
			ui.addNotification(null, E('p', {}, _('Paste a VLESS link first.')));
			return;
		}

		return this.runAction(['add', value], _('Saving VLESS profile')).then(function() {
			if (input)
				input.value = '';
		});
	},

	handleSelect: function(id, ev) {
		if (ev)
			ev.preventDefault();

		ui.showModal(_('Switch VLESS profile'), [
			E('p', {}, _('Apply this profile and restart Xray?')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-positive',
					'disabled': isReadonlyView,
					'click': L.bind(function() {
						this.runAction(['select', id], _('Switching VLESS profile'));
					}, this)
				}, _('Apply'))
			])
		]);
	},

	handleDelete: function(id, ev) {
		if (ev)
			ev.preventDefault();

		if (!confirm(_('Delete this saved VLESS profile?')))
			return;

		return this.runAction(['delete', id], _('Deleting VLESS profile'));
	},

	handleApplyRules: function() {
		var domains = document.querySelector('#vpn-direct-domains');
		var ips = document.querySelector('#vpn-direct-ips');

		return this.runAction([
			'apply-rules',
			domains ? domains.value : '',
			ips ? ips.value : ''
		], _('Applying direct routing rules'));
	},

	load: function() {
		return this.callHelper(['status']);
	},

	renderProfileTable: function(data) {
		var profiles = data.profiles || [];
		var rows = profiles.map(function(profile) {
			var selected = !!profile.selected;
			var pingClass = profile.ping == 'timeout' ? 'vpn-ping-bad' : 'vpn-ping-ok';

			return E('tr', { 'class': 'tr vpn-profile-row' + (selected ? ' vpn-selected' : '') }, [
				E('td', { 'class': 'td left' }, [
					E('button', {
						'class': 'cbi-button ' + (selected ? 'cbi-button-positive' : 'cbi-button-action'),
						'disabled': selected || isReadonlyView,
						'click': L.bind(this.handleSelect, this, profile.id)
					}, selected ? _('Selected') : _('Use'))
				]),
				E('td', { 'class': 'td left' }, [
					E('div', { 'class': 'vpn-profile-title' }, profile.name || profile.host),
					E('div', { 'class': 'vpn-muted' }, '%s:%s'.format(profile.host, profile.port))
				]),
				E('td', { 'class': 'td left' }, [
					E('div', {}, profile.protocol || 'vless'),
					E('div', { 'class': 'vpn-muted' }, profile.vps_ip || '-')
				]),
				E('td', { 'class': 'td left' }, [
					E('span', { 'class': pingClass }, profile.ping || '-')
				]),
				E('td', { 'class': 'td left' }, [
					E('span', { 'class': 'label' + (selected ? ' notice' : '') }, selected ? _('Enabled') : _('Saved'))
				]),
				E('td', { 'class': 'td right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'disabled': selected || isReadonlyView,
						'click': L.bind(this.handleDelete, this, profile.id)
					}, _('Delete'))
				])
			]);
		}, this);

		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th left' }, _('Use')),
				E('th', { 'class': 'th left' }, _('Node')),
				E('th', { 'class': 'th left' }, _('Protocol')),
				E('th', { 'class': 'th left' }, _('Ping')),
				E('th', { 'class': 'th left' }, _('Status')),
				E('th', { 'class': 'th right' }, '')
			])
		].concat(rows.length ? rows : [
			E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': '6' }, _('No VLESS profiles saved.'))
			])
		]));
	},

	renderProfiles: function(data) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('VLESS profiles')),
			E('div', { 'class': 'vpn-service-row' }, [
				E('span', { 'class': 'label' }, 'Xray: %s'.format((data.services || {}).xray || '-')),
				E('span', { 'class': 'label' }, 'TProxy: %s'.format((data.services || {}).transparent || '-'))
			]),
			E('div', { 'class': 'vpn-add-row' }, [
				E('input', {
					'id': 'vpn-vless-url',
					'type': 'text',
					'placeholder': 'vless://...',
					'disabled': isReadonlyView
				}),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleAdd')
				}, _('Add')),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, 'handleRefresh')
				}, _('Refresh pings'))
			]),
			this.renderProfileTable(data)
		]);
	},

	renderRules: function(data) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Direct routing rules')),
			E('div', { 'class': 'vpn-rules-grid' }, [
				E('div', {}, [
					E('label', { 'class': 'cbi-value-title', 'for': 'vpn-direct-domains' }, _('Domains')),
					E('textarea', {
						'id': 'vpn-direct-domains',
						'spellcheck': 'false',
						'wrap': 'off',
						'disabled': isReadonlyView
					}, lines(data.domains))
				]),
				E('div', {}, [
					E('label', { 'class': 'cbi-value-title', 'for': 'vpn-direct-ips' }, _('IP addresses')),
					E('textarea', {
						'id': 'vpn-direct-ips',
						'spellcheck': 'false',
						'wrap': 'off',
						'disabled': isReadonlyView
					}, lines(data.ips))
				])
			]),
			E('div', { 'class': 'vpn-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleApplyRules')
				}, _('Apply rules'))
			])
		]);
	},

	renderBody: function(data) {
		return [
			this.renderProfiles(data),
			this.renderRules(data)
		];
	},

	render: function(data) {
		this.data = data;

		return E('div', { 'class': 'cbi-map vpn-ui' }, [
			E('style', {}, css),
			E('h2', {}, _('VPN')),
			E('div', { 'id': 'vpn-ui-root' }, this.renderBody(data))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
