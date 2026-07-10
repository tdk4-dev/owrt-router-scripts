'use strict';
'require view';
'require fs';
'require ui';
'require tools.router_footer as routerFooter';

var helper = '/usr/sbin/vpn-ui';
var css = '\
.adguard-ui .adguard-card { max-width:52rem; border:1px solid #444; border-radius:.65rem; padding:1rem 1.1rem; background:rgba(255,255,255,.025); }\
.adguard-ui .adguard-state { display:flex; gap:.5rem; flex-wrap:wrap; margin:.75rem 0 1rem; }\
.adguard-ui .adguard-note { opacity:.72; margin:.5rem 0 1rem; max-width:46rem; }\
';

function parseResponse(res) {
	var output = (res && res.stdout) ? res.stdout.trim() : '';
	var data;
	try {
		data = JSON.parse(output || '{}');
	}
	catch (e) {
		throw new Error(output || _('AdGuardHome status is unavailable.'));
	}
	if (!data.ok)
		throw new Error(data.error || _('AdGuardHome status is unavailable.'));
	return data;
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec(helper, ['adguard-status']).then(parseResponse),
			fs.exec(helper, ['footer-info']).then(parseResponse)
		]).then(function(result) {
			result[0].metadata = result[1];
			return result[0];
		});
	},

	openPanel: function() {
		window.location.href = 'http://' + window.location.hostname + ':3000/';
	},

	render: function(data) {
		var installed = !!data.installed;
		var running = !!data.running;
		routerFooter.apply(data.metadata);

		return E('div', { 'class': 'cbi-map adguard-ui' }, [
			E('style', {}, css),
			E('h2', {}, _('AdGuardHome')),
			E('div', { 'class': 'adguard-card' }, [
				E('h3', {}, _('DNS filtering panel')),
				E('div', { 'class': 'adguard-state' }, [
					E('span', { 'class': 'label ' + (installed ? 'notice' : 'warning') }, installed ? _('Installed') : _('Not installed')),
					E('span', { 'class': 'label ' + (running ? 'notice' : 'warning') }, running ? _('Running') : _('Stopped'))
				]),
				E('p', { 'class': 'adguard-note' }, installed
					? _('AdGuardHome uses its own web interface on port 3000. Open it to manage DNS filtering, clients, and query logs.')
					: _('AdGuardHome is optional and is not installed on this router. It can be installed from the first-boot setup assistant when writable storage has enough safe free space.')),
				E('button', {
					'class': 'cbi-button cbi-button-action important',
					'disabled': installed ? null : 'disabled',
					'click': ui.createHandlerFn(this, 'openPanel')
				}, _('Open AdGuardHome web panel'))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
