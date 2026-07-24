'use strict';
'require view';
'require fs';
'require ui';
'require dom';

var helper = '/usr/sbin/vpn-ui';
var readonlyHelper = '/usr/sbin/vpn-ui-readonly';
var isReadonlyView = !L.hasViewPermission() || null;
var css = '\
.router-update .update-hero { display:flex; justify-content:space-between; align-items:flex-start; gap:1rem; flex-wrap:wrap; margin-bottom:1.25rem; }\
.router-update .update-subtitle { opacity:.7; max-width:48rem; margin:.25rem 0 0; }\
.router-update .update-cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:1rem; margin:1rem 0 1.5rem; }\
.router-update .update-card { border:1px solid #444; border-radius:.75rem; padding:1.15rem; background:rgba(255,255,255,.025); min-height:6rem; }\
.router-update .update-card-label { display:block; opacity:.65; font-size:.88em; margin-bottom:.45rem; }\
.router-update .update-card-value { display:block; font-size:1.45em; font-weight:700; }\
.router-update .update-card-note { display:block; opacity:.7; margin-top:.35rem; overflow-wrap:anywhere; }\
.router-update .update-notes { white-space:pre-wrap; overflow-wrap:anywhere; font-family:inherit; line-height:1.55; border:1px solid #444; border-radius:.5rem; padding:1rem; background:rgba(255,255,255,.018); }\
.router-update .update-actions { display:flex; gap:.5rem; flex-wrap:wrap; }\
.router-update .update-setting { display:flex; align-items:flex-start; gap:.65rem; padding:.9rem 0; }\
.router-update .update-setting input { margin-top:.25rem; }\
.router-update .update-job { border-left:3px solid #09c; padding:.65rem .9rem; margin:1rem 0; background:rgba(0,153,204,.08); }\
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
		return fs.exec(args && args[0] === 'update-status' ? readonlyHelper : helper, args).then(parseResponse);
	},

	load: function() {
		return this.callHelper(['update-status']);
	},

	updateView: function(data) {
		this.data = data;
		var root = document.querySelector('#router-update-root');
		if (root)
			dom.content(root, this.renderBody(data));
	},

	pollJob: function(kind, failures) {
		failures = failures || 0;
		return new Promise(L.bind(function(resolve, reject) {
			window.setTimeout(L.bind(function() {
				this.callHelper(['update-status']).then(L.bind(function(data) {
					var job = data.job || {};
					this.updateView(data);
					if (job.status === 'starting' || job.status === 'running') {
						this.pollJob(kind, 0).then(resolve, reject);
						return;
					}
					if (job.status === 'failed') {
						reject(new Error(job.message || _('The update task failed safely.')));
						return;
					}
					resolve(data);
				}, this)).catch(L.bind(function(err) {
					if (kind === 'apply' && failures >= 8) {
						window.setTimeout(function() { window.location.reload(); }, 2500);
						return;
					}
					if (failures < 150) {
						this.pollJob(kind, failures + 1).then(resolve, reject);
						return;
					}
					reject(err);
				}, this));
			}, this), 1200);
		}, this));
	},

	startJob: function(kind) {
		var isInstall = kind === 'apply';
		ui.showModal(isInstall ? _('Installing router update') : _('Checking for updates'), [
			E('p', { 'class': 'spinning' }, isInstall
				? _('A full backup is created before any files change. LuCI may restart briefly.')
				: _('Contacting the release server…'))
		]);
		return this.callHelper([isInstall ? 'update-apply-start' : 'update-check-start'])
			.then(L.bind(function() { return this.pollJob(kind, 0); }, this))
			.then(L.bind(function(data) {
				ui.hideModal();
				this.updateView(data);
				if (isInstall) {
					ui.addNotification(null, E('p', {}, _('Update installed and validated. Reloading…')));
					window.setTimeout(function() { window.location.reload(); }, 1500);
				}
			}, this))
			.catch(function(err) {
				ui.hideModal();
				if (isInstall) {
					ui.addNotification(null, E('p', {}, _('LuCI restarted during the update. Reloading this page…')));
					window.setTimeout(function() { window.location.reload(); }, 2500);
					return;
				}
				ui.addNotification(null, E('p', {}, err.message || err));
			});
	},

	refresh: function() {
		return this.startJob('check');
	},

	install: function() {
		if (!confirm(_('Install this router software update now? A full OpenWrt backup will be created first.')))
			return;
		return this.startJob('apply');
	},

	setAutoUpdate: function(enabled) {
		return this.callHelper(['update-auto', enabled ? '1' : '0']).then(L.bind(function(data) {
			this.updateView(data);
			ui.addNotification(null, E('p', {}, enabled
				? _('Weekly automatic updates enabled.')
				: _('Weekly automatic updates disabled.')));
		}, this)).catch(L.bind(function(err) {
			ui.addNotification(null, E('p', {}, err.message || err));
		}, this));
	},

	renderBody: function(data) {
		var job = data.job || {};
		var busy = job.status === 'starting' || job.status === 'running';
		var checkedNote = data.checked_at
			? _('Last checked: %s').format(data.checked_at.replace('T', ' ').replace('Z', ' UTC'))
			: _('Not checked yet');

		return [
			E('div', { 'class': 'update-hero' }, [
				E('div', {}, [
					E('h2', {}, _('Router software update')),
					E('p', { 'class': 'update-subtitle' }, _('Updates are checksum-verified, backed up before installation, validated afterward, and automatically rolled back if installation or validation fails.'))
				]),
				E('div', { 'class': 'update-actions' }, [
					E('a', {
						'class': 'cbi-button cbi-button-action',
						'href': '#',
						'aria-disabled': busy || isReadonlyView ? 'true' : 'false',
						'click': L.bind(function(ev) {
							ev.preventDefault();
							if (!busy && !isReadonlyView)
								return this.refresh();
						}, this)
					}, _('Check again')),
					E('a', {
						'class': 'cbi-button cbi-button-positive',
						'href': '#',
						'aria-disabled': busy || !data.available || isReadonlyView ? 'true' : 'false',
						'click': L.bind(function(ev) {
							ev.preventDefault();
							if (!busy && data.available && !isReadonlyView)
								return this.install();
						}, this)
					}, data.available ? _('Download and install') : _('Up to date'))
				])
			]),
			busy || job.message ? E('div', { 'class': 'update-job' }, [
				E('strong', {}, busy ? _('Update task in progress') : (job.status === 'failed' ? _('Last update task failed safely') : _('Last update task'))),
				E('div', {}, job.message || '-'),
				job.backup ? E('small', {}, _('Backup: %s').format(job.backup)) : ''
			]) : '',
			E('div', { 'class': 'update-cards' }, [
				E('div', { 'class': 'update-card' }, [
					E('span', { 'class': 'update-card-label' }, _('Installed')),
					E('span', { 'class': 'update-card-value' }, data.current || '-'),
					E('span', { 'class': 'update-card-note' }, _('Currently running on this router'))
				]),
				E('div', { 'class': 'update-card' }, [
					E('span', { 'class': 'update-card-label' }, _('Latest release')),
					E('span', { 'class': 'update-card-value' }, data.latest || '-'),
					E('span', { 'class': 'update-card-note' }, data.released_at || checkedNote)
				]),
				E('div', { 'class': 'update-card' }, [
					E('span', { 'class': 'update-card-label' }, _('Status')),
					E('span', { 'class': 'update-card-value' }, data.available ? _('Update available') : _('Up to date')),
					E('span', { 'class': 'update-card-note' }, checkedNote)
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Automatic updates')),
				E('div', { 'class': 'update-setting' }, [
					E('a', {
						'class': 'cbi-button ' + (data.auto_update ? 'cbi-button-positive' : 'cbi-button-neutral'),
						'href': '#',
						'aria-disabled': busy || isReadonlyView ? 'true' : 'false',
						'click': L.bind(function(ev) {
							ev.preventDefault();
							if (!busy && !isReadonlyView)
								return this.setAutoUpdate(!data.auto_update);
						}, this)
					}, data.auto_update ? _('Weekly updates enabled') : _('Enable weekly updates')),
					E('span', {}, [
						E('strong', {}, data.auto_update ? _('Stable releases install once a week') : _('Automatic installation is disabled')),
						E('br'),
						E('span', {}, _('Schedule: %s. The same backup, validation, and rollback protections are used.').format(data.auto_schedule || _('Sunday 04:17')))
					])
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('What’s new in %s').format(data.latest || _('the latest release'))),
				E('pre', { 'class': 'update-notes' }, data.changelog || _('Check for updates to download the latest changelog.'))
			])
		];
	},

	render: function(data) {
		this.data = data;
		if (!isReadonlyView && !data.checked_at && !(data.job && (data.job.status === 'starting' || data.job.status === 'running')))
			window.setTimeout(L.bind(function() { this.refresh(); }, this), 250);
		return E('div', { 'class': 'cbi-map router-update' }, [
			E('style', {}, css),
			E('div', { 'id': 'router-update-root' }, this.renderBody(data))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
