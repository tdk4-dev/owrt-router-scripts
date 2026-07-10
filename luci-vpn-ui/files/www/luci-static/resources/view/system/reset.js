'use strict';
'require view';
'require fs';
'require ui';

var helper = '/usr/sbin/vpn-ui';
var css = '\
.router-reset .reset-hero { max-width:58rem; margin-bottom:1.25rem; }\
.router-reset .reset-subtitle { opacity:.7; max-width:48rem; margin:.35rem 0 0; }\
.router-reset .reset-panel { border:1px solid #633; border-radius:.5rem; padding:1rem; background:rgba(170,40,40,.08); max-width:58rem; }\
.router-reset .reset-panel h3 { margin-top:0; }\
.router-reset .reset-list { margin:.75rem 0 1rem 1.25rem; }\
.router-reset .reset-actions { display:flex; gap:.6rem; flex-wrap:wrap; margin-top:1rem; }\
.router-reset .reset-muted { opacity:.7; }\
.router-reset-progress { min-width:22rem; }\
.router-reset-progress .reset-wait { color:#aaa; margin-top:.7rem; }\
.router-reset .router-panel-footer { display:flex; justify-content:space-between; gap:.5rem 1rem; flex-wrap:wrap; border-top:1px solid #444; margin-top:1.5rem; padding-top:.9rem; opacity:.72; font-size:.88em; }\
';

function parseResponse(res) {
	var data, output = (res && res.stdout) ? res.stdout.trim() : '';

	try {
		data = JSON.parse(output || '{}');
	}
	catch (e) {
		throw new Error(output || _('The reset helper returned an unreadable response.'));
	}

	if (!data.ok)
		throw new Error(data.error || _('The reset helper rejected the request.'));

	return data;
}

function renderPanelFooter(metadata) {
	metadata = metadata || {};
	if (metadata.footer_enabled === false)
		return '';
	return E('div', { 'class': 'router-panel-footer' }, [
		E('span', {}, metadata.version ? _('Router Scripts v%s').format(metadata.version) : _('Router Scripts version unavailable')),
		E('span', {}, _('Support: %s · Registration: %s').format(metadata.support_level || _('unknown'), metadata.registration_state || _('unknown')))
	]);
}

return view.extend({
	callHelper: function(args) {
		return fs.exec(helper, args).then(parseResponse);
	},

	load: function() {
		return Promise.all([
			this.callHelper(['reset-status']),
			this.callHelper(['footer-info'])
		]).then(function(result) {
			result[0].metadata = result[1];
			return result[0];
		});
	},

	waitForSetup: function(startedAt) {
		var self = this;
		return window.fetch('/cgi-bin/firstboot-setup?action=status&_=' + Date.now(), {
			'cache': 'no-store',
			'credentials': 'same-origin'
		}).then(function(res) {
			if (!res.ok)
				throw new Error('not ready');
			return res.json();
		}).then(function(data) {
			if (data && data.ok && data.complete === false) {
				window.location.href = '/setup/';
				return;
			}

			if (Date.now() - startedAt > 120000) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('Reset is taking longer than expected. Wait for the router to finish rebooting, then open the router address again.')));
				return;
			}

			window.setTimeout(function() {
				self.waitForSetup(startedAt);
			}, 3000);
		}).catch(function() {
			if (Date.now() - startedAt > 120000) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('The router is rebooting. Open the router address again once it comes back online.')));
				return;
			}

			window.setTimeout(function() {
				self.waitForSetup(startedAt);
			}, 3000);
		});
	},

	resetRouter: function(data) {
		var typed, self = this;

		if (!data.supported) {
			ui.addNotification(null, E('p', {}, _('This reset action is only available on images with the first-boot setup assistant.')));
			return;
		}

		if (!confirm(_('Are you sure you want to reset this router and reboot back to setup? Current configuration, passwords, VPN profiles, Tailscale login, AdGuard state, and Wi-Fi settings will be removed.')))
			return;

		typed = prompt(_('Type RESET to confirm router reset.'));
		if (typed !== 'RESET') {
			ui.addNotification(null, E('p', {}, _('Router reset cancelled.')));
			return;
		}

		ui.showModal(_('Resetting router'), [
			E('div', { 'class': 'router-reset-progress' }, [
				E('p', { 'class': 'spinning' }, _('Factory reset has been requested.')),
				E('p', { 'class': 'reset-wait' }, _('Keep this tab open. The page will switch to the setup assistant when the router is ready.'))
			]),
			renderPanelFooter(data.metadata)
		]);

		return this.callHelper(['reset-to-setup', 'RESET']).then(function(result) {
			window.setTimeout(function() {
				self.waitForSetup(Date.now());
			}, 12000);
		}).catch(function(err) {
			window.setTimeout(function() {
				self.waitForSetup(Date.now());
			}, 12000);
		});
	},

	render: function(data) {
		var supported = data && data.supported;
		return E('div', { 'class': 'cbi-map router-reset' }, [
			E('style', {}, css),
			E('div', { 'class': 'reset-hero' }, [
				E('h2', {}, _('Reset router')),
				E('p', { 'class': 'reset-subtitle' }, _('Reset this custom image back to the first-boot setup assistant. Use this before handing the router to another user or when setup should be repeated from scratch.'))
			]),
			E('div', { 'class': 'reset-panel' }, [
				E('h3', {}, _('Reset to setup')),
				E('p', {}, _('This will erase the writable router configuration and reboot. After reboot, opening the router address will show the setup assistant again.')),
				E('ul', { 'class': 'reset-list' }, [
					E('li', {}, _('Root password and SSH keys are removed.')),
					E('li', {}, _('VPN profiles, direct-routing rules, and device bypass settings are removed.')),
					E('li', {}, _('Tailscale login, AdGuardHome state, and Wi-Fi settings are removed.'))
				]),
				supported ? '' : E('p', { 'class': 'reset-muted' }, _('The first-boot setup assistant was not detected on this router, so reset is disabled.')),
				E('div', { 'class': 'reset-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'disabled': supported ? null : 'disabled',
						'click': L.bind(function(ev) {
							ev.preventDefault();
							return this.resetRouter(data);
						}, this)
					}, _('Reset and reboot to setup'))
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
