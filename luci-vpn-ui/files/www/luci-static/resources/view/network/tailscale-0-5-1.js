'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var helper = '/usr/sbin/vpn-ui';
var isReadonlyView = !L.hasViewPermission() || null;

var css = '\
.tailscale-ui .ts-state { display:flex; gap:.5rem; flex-wrap:wrap; margin:.5rem 0 1rem; }\
.tailscale-ui .ts-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:1rem; }\
.tailscale-ui .ts-field label { display:block; margin-bottom:.35rem; }\
.tailscale-ui .ts-field input[type="text"], .tailscale-ui .ts-field input[type="password"] { width:100%; box-sizing:border-box; }\
.tailscale-ui .ts-check { display:flex; gap:.5rem; align-items:center; min-height:2.2rem; }\
.tailscale-ui .ts-actions { display:flex; justify-content:flex-end; gap:.5rem; flex-wrap:wrap; margin-top:1rem; }\
.tailscale-ui .ts-note { opacity:.72; margin:.5rem 0 1rem; }\
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
		return fs.exec(helper, args).then(parseResponse);
	},

	load: function() {
		return this.callHelper(['status']);
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

	renderBody: function(data) {
		var tailscale = data.tailscale || {};

		return E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'ts-state' }, [
				E('span', { 'class': 'label ' + (tailscale.connected ? 'notice' : 'warning') },
					tailscale.connected ? _('Connected') : _('Disconnected')),
				E('span', { 'class': 'label' }, _('Service: %s').format(tailscale.running ? _('running') : _('stopped'))),
				E('span', { 'class': 'label' }, 'IP: %s'.format(tailscale.ip || '-')),
				E('span', { 'class': 'label' }, 'Control: %s'.format(tailscale.control_url || '-'))
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
		]);
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
