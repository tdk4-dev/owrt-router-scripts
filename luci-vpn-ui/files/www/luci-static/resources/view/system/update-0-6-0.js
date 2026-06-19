'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var helper = '/usr/sbin/vpn-ui';
var isReadonlyView = !L.hasViewPermission() || null;

var css = '\
.router-update .update-hero { display:flex; justify-content:space-between; align-items:flex-start; gap:1rem; flex-wrap:wrap; margin-bottom:1.25rem; }\
.router-update .update-subtitle { opacity:.7; max-width:48rem; margin:.25rem 0 0; }\
.router-update .update-cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:1rem; margin:1rem 0 1.5rem; }\
.router-update .update-card { border:1px solid #444; border-radius:.75rem; padding:1.15rem; background:rgba(255,255,255,.025); min-height:6rem; }\
.router-update .update-card-label { display:block; opacity:.65; font-size:.88em; margin-bottom:.45rem; }\
.router-update .update-card-value { display:block; font-size:1.45em; font-weight:700; }\
.router-update .update-card-note { display:block; opacity:.7; margin-top:.35rem; }\
.router-update .update-status { display:flex; gap:.5rem; align-items:center; flex-wrap:wrap; margin:.75rem 0; }\
.router-update .update-notes { white-space:pre-wrap; overflow-wrap:anywhere; font-family:inherit; line-height:1.55; border:1px solid #444; border-radius:.5rem; padding:1rem; background:rgba(255,255,255,.018); }\
.router-update .update-actions { display:flex; gap:.5rem; flex-wrap:wrap; }\
';

function parseResponse(res) {
	var data, output = (res && res.stdout) ? res.stdout.trim() : '';

	try {
		data = JSON.parse(output);
	}
	catch (e) {
		throw new Error(output || _('The update helper returned an unreadable response.'));
	}

	if (!data.ok)
		throw new Error(data.error || _('The update helper rejected the request.'));

	return data;
}

return view.extend({
	callHelper: function(args) {
		return fs.exec(helper, args).then(parseResponse);
	},

	load: function() {
		return this.callHelper(['update-check']);
	},

	refresh: function() {
		ui.showModal(_('Checking for updates'), [
			E('p', { 'class': 'spinning' }, _('Contacting the release server...'))
		]);
		return this.callHelper(['update-check']).then(L.bind(function(data) {
			ui.hideModal();
			this.data = data;
			dom.content(document.querySelector('#router-update-root'), this.renderBody(data));
		}, this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	install: function() {
		if (!confirm(_('Install this router software update now? Services may restart briefly.')))
			return;

		ui.showModal(_('Installing router update'), [
			E('p', { 'class': 'spinning' }, _('Downloading, verifying, backing up, and installing the release...'))
		]);
		return this.callHelper(['update-apply']).then(function(data) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Router software updated to %s. Reloading...').format(data.current || '-')));
			window.setTimeout(function() { window.location.reload(); }, 1500);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	renderBody: function(data) {
		return [
			E('div', { 'class': 'update-hero' }, [
				E('div', {}, [
					E('h2', {}, _('Router software update')),
					E('p', { 'class': 'update-subtitle' }, _('One release can update VPN, Tailscale, LuCI pages, router helpers, and other managed configuration while preserving a rollback snapshot.'))
				]),
				E('div', { 'class': 'update-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'refresh')
					}, _('Check again')),
					E('button', {
						'class': 'cbi-button cbi-button-positive',
						'disabled': isReadonlyView || !data.available,
						'click': ui.createHandlerFn(this, 'install')
					}, data.available ? _('Download and install') : _('Up to date'))
				])
			]),
			E('div', { 'class': 'update-cards' }, [
				E('div', { 'class': 'update-card' }, [
					E('span', { 'class': 'update-card-label' }, _('Installed')),
					E('span', { 'class': 'update-card-value' }, data.current || '-'),
					E('span', { 'class': 'update-card-note' }, _('Currently running on this router'))
				]),
				E('div', { 'class': 'update-card' }, [
					E('span', { 'class': 'update-card-label' }, _('Latest release')),
					E('span', { 'class': 'update-card-value' }, data.latest || '-'),
					E('span', { 'class': 'update-card-note' }, data.released_at || _('Release date unavailable'))
				]),
				E('div', { 'class': 'update-card' }, [
					E('span', { 'class': 'update-card-label' }, _('Status')),
					E('span', { 'class': 'update-card-value' }, data.available ? _('Update available') : _('Up to date')),
					E('span', { 'class': 'update-card-note' }, _('Release bundles are verified with SHA-256 before installation'))
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('What’s new in %s').format(data.latest || _('the latest release'))),
				E('pre', { 'class': 'update-notes' }, data.changelog || _('No changelog was provided for this release.'))
			])
		];
	},

	render: function(data) {
		this.data = data;
		return E('div', { 'class': 'cbi-map router-update' }, [
			E('style', {}, css),
			E('div', { 'id': 'router-update-root' }, this.renderBody(data))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
