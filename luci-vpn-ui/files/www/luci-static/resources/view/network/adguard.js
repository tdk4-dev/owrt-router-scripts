'use strict';
'require view';
'require fs';
'require ui';
'require tools.router_footer as routerFooter';

var helper = '/usr/sbin/vpn-ui';
var css = '\
.adguard-ui .adguard-card { max-width:58rem; border:1px solid #444; border-radius:.65rem; padding:1rem 1.1rem; background:rgba(255,255,255,.025); margin-bottom:1rem; }\
.adguard-ui .adguard-state { display:flex; gap:.5rem; flex-wrap:wrap; margin:.75rem 0 1rem; }\
.adguard-ui .adguard-note { opacity:.76; margin:.5rem 0 1rem; max-width:50rem; line-height:1.5; }\
.adguard-ui .storage-heading { display:flex; justify-content:space-between; gap:1rem; flex-wrap:wrap; }\
.adguard-ui .storage-heading small { display:block; opacity:.7; margin-top:.2rem; }\
.adguard-ui .storage-bar { height:1.15rem; border:1px solid #555; border-radius:.35rem; overflow:hidden; display:flex; margin:.9rem 0 .7rem; background:rgba(0,0,0,.25); }\
.adguard-ui .storage-used { background:#7d8990; }\
.adguard-ui .storage-estimate { background:#8e5bd7; }\
.adguard-ui .storage-legend { display:flex; gap:1rem; flex-wrap:wrap; opacity:.75; font-size:.9em; }\
.adguard-ui .storage-warning { margin-top:1rem; padding:.75rem .85rem; border-radius:.35rem; border:1px solid #8c6523; background:rgba(171,116,23,.13); }\
.adguard-ui .storage-warning.blocked { border-color:#a43b32; background:rgba(164,59,50,.16); }\
.adguard-ui .detail-grid { display:grid; grid-template-columns:minmax(10rem,14rem) 1fr; gap:.65rem 1rem; margin:1rem 0; }\
.adguard-ui .detail-grid dt { opacity:.68; }\
.adguard-ui .detail-grid dd { margin:0; overflow-wrap:anywhere; }\
.adguard-ui .adguard-actions { display:flex; gap:.65rem; flex-wrap:wrap; margin-top:1rem; }\
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

function formatBytes(bytes) {
	var value = Number(bytes || 0);
	if (value >= 1073741824)
		return (value / 1073741824).toFixed(1) + ' GiB';
	if (value >= 1048576)
		return Math.round(value / 1048576) + ' MiB';
	return Math.round(value / 1024) + ' KiB';
}

function percentage(value) {
	return Math.max(0, Math.min(100, Number(value || 0)));
}

return view.extend({
	callHelper: function(args) {
		return fs.exec(helper, args).then(parseResponse);
	},

	load: function() {
		return Promise.all([
			this.callHelper(['adguard-status']),
			this.callHelper(['footer-info'])
		]).then(function(result) {
			result[0].metadata = result[1];
			return result[0];
		});
	},

	openPanel: function() {
		window.location.href = 'http://' + window.location.hostname + ':3000/';
	},

	install: function() {
		if (!confirm(_('Install AdGuardHome from the signed OpenWrt package feed? DNS settings will not be changed automatically.')))
			return;
		ui.showModal(_('Installing AdGuardHome'), [
			E('p', { 'class': 'spinning' }, _('Refreshing the signed package feed and installing AdGuardHome. No global package upgrade is run.'))
		]);
		return this.callHelper(['adguard-install']).then(function() {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('AdGuardHome installed. Reloading its status…')));
			window.setTimeout(function() { window.location.reload(); }, 900);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	renderStorage: function(data) {
		var storage = data.storage || {};
		var used = percentage(storage.usedPercent);
		var estimate = Math.max(0, Math.min(100 - used, percentage(storage.projectedUsedPercent) - used));
		var risk = storage.risk || 'unknown';
		var warning = '';

		if (risk === 'blocked')
			warning = _('Installation would fill approximately %s%% of persistent storage. AdGuardHome cannot be installed safely.').format(storage.projectedUsedPercent || '?');
		else if (risk === 'warning')
			warning = _('Installation would fill approximately %s%% of persistent storage. This leaves little room for settings and future updates.').format(storage.projectedUsedPercent || '?');
		else if (risk === 'unknown')
			warning = _('Persistent storage capacity could not be measured, so installation is unavailable.');

		return E('div', { 'class': 'adguard-card' }, [
			E('div', { 'class': 'storage-heading' }, [
				E('div', {}, [
					E('strong', {}, _('Persistent storage')),
					E('small', {}, _('%s free of %s').format(formatBytes(storage.freeBytes), formatBytes(storage.totalBytes)))
				]),
				E('strong', {}, _('%s%% projected').format(storage.projectedUsedPercent || '?'))
			]),
			E('div', { 'class': 'storage-bar', 'aria-label': _('Persistent storage usage') }, [
				E('span', { 'class': 'storage-used', 'style': 'width:' + used + '%' }),
				E('span', { 'class': 'storage-estimate', 'style': 'width:' + estimate + '%' })
			]),
			E('div', { 'class': 'storage-legend' }, [
				E('span', {}, _('Used %s').format(formatBytes(storage.usedBytes))),
				E('span', {}, _('AdGuardHome estimate %s').format(formatBytes(storage.estimatedInstallBytes))),
				E('span', {}, _('Currently free %s').format(formatBytes(storage.freeBytes)))
			]),
			warning ? E('div', { 'class': 'storage-warning ' + (risk === 'blocked' ? 'blocked' : '') }, warning) : ''
		]);
	},

	render: function(data) {
		var installed = !!data.installed;
		var running = !!data.running;
		var supported = data.install_supported !== false;
		var children = [];
		routerFooter.apply(data.metadata);

		children.push(E('style', {}, css));
		children.push(E('h2', {}, _('AdGuardHome')));
		children.push(E('div', { 'class': 'adguard-card' }, [
				E('h3', {}, _('Network-wide DNS filtering')),
				E('div', { 'class': 'adguard-state' }, [
					E('span', { 'class': 'label ' + (installed ? 'notice' : 'warning') }, installed ? _('Installed') : _('Not installed')),
					installed ? E('span', { 'class': 'label ' + (running ? 'notice' : 'warning') }, running ? _('Running') : _('Stopped')) : '',
					installed ? E('span', { 'class': 'label ' + (data.enabled ? 'notice' : 'warning') }, data.enabled ? _('Starts at boot') : _('Disabled at boot')) : ''
				]),
				E('p', { 'class': 'adguard-note' }, installed
					? _('AdGuardHome filters DNS requests for the whole router network. Its own web panel manages blocklists, clients, upstream DNS servers, and query logging.')
					: _('AdGuardHome is an optional network-wide DNS filtering service. It can block advertising, trackers, and known malicious domains for devices using this router.')),
				!supported ? E('div', { 'class': 'storage-warning' }, data.deferred_reason || _('AdGuardHome is not included or recommended for this hardware profile.')) : '',
				installed ? E('dl', { 'class': 'detail-grid' }, [
					E('dt', {}, _('Web interface')), E('dd', {}, data.listen || '0.0.0.0:3000'),
					E('dt', {}, _('Query logging')), E('dd', {}, data.query_logging === 'true' ? _('Enabled') : (data.query_logging === 'false' ? _('Disabled') : _('Unknown'))),
					E('dt', {}, _('Enabled filters')), E('dd', {}, String(data.filter_count || 0)),
					E('dt', {}, _('Upstream DNS entries')), E('dd', {}, String(data.upstream_count || 0))
				]) : ''
			]));

		if (!installed && supported)
			children.push(this.renderStorage(data));

		children.push(E('div', { 'class': 'adguard-actions' }, [
			!installed && supported ? E('button', {
				'class': 'cbi-button cbi-button-action important',
				'disabled': data.can_install ? null : 'disabled',
				'click': ui.createHandlerFn(this, 'install')
			}, _('Install AdGuardHome (%s)').format(formatBytes((data.storage || {}).estimatedInstallBytes))) : '',
			installed ? E('button', {
				'class': 'cbi-button cbi-button-action important',
				'click': ui.createHandlerFn(this, 'openPanel')
			}, _('Open AdGuardHome web panel')) : ''
		]));

		return E('div', { 'class': 'cbi-map adguard-ui' }, children);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
