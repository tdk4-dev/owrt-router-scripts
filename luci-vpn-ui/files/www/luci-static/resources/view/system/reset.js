'use strict';
'require view';
'require fs';
'require ui';
'require tools.router_footer as routerFooter';

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
.router-reset-progress ol { margin:.8rem 0 .4rem 1.3rem; padding:0; }\
.router-reset-progress li { margin:.35rem 0; }\
.router-reset-progress .reset-wait { color:#aaa; margin-top:.7rem; }\
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

	resetRouter: function(data) {
		var typed;

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
				E('p', { 'class': 'spinning' }, _('Sending the reset request…')),
				E('ol', {}, [
					E('li', {}, _('Stop router services safely.')),
					E('li', {}, _('Erase writable configuration and credentials.')),
					E('li', {}, _('Restart OpenWrt. The router will be temporarily offline.')),
					E('li', {}, _('Open the fresh setup assistant.'))
				]),
				E('p', { 'class': 'reset-wait' }, _('You will be moved to a public progress page that survives sign-out and reloads.'))
			])
		]);

		var progressUrl = '/setup/?reset=1';
		var handoffTimer;
		try {
			window.localStorage.setItem('premier-router-reset-started-at', String(Date.now()));
		}
		catch (e) {}

		/* The router may reboot before LuCI can finish the RPC response. Move to
		 * the public progress page independently so the UI never remains stuck
		 * behind an authenticated modal after credentials are erased. */
		handoffTimer = window.setTimeout(function() {
			window.location.replace(progressUrl);
		}, 1200);

		return this.callHelper(['reset-to-setup', 'RESET']).then(function(result) {
			window.clearTimeout(handoffTimer);
			window.location.replace(result.progress_url || progressUrl);
		}).catch(function() {
			window.clearTimeout(handoffTimer);
			window.location.replace(progressUrl);
		});
	},

	render: function(data) {
		var supported = data && data.supported;
		routerFooter.apply(data && data.metadata);
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
