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
.vpn-ui .vpn-table-wrap { overflow-x:auto; }\
.vpn-ui .vpn-settings-grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(220px, 1fr)); gap:1rem; align-items:end; }\
.vpn-ui .vpn-setting label { display:block; margin-bottom:.35rem; }\
.vpn-ui .vpn-setting input[type="text"], .vpn-ui .vpn-setting input[type="password"], .vpn-ui .vpn-setting input[type="number"] { width:100%; box-sizing:border-box; }\
.vpn-ui .vpn-check-row { display:flex; gap:.5rem; align-items:center; min-height:2.2rem; }\
.vpn-ui .vpn-section-note { margin:.35rem 0 1rem; }\
.vpn-ui .vpn-profile-row.vpn-selected { background:#173d25 !important; }\
.vpn-ui .vpn-profile-row.vpn-selected > .td { background:transparent !important; }\
.vpn-ui .vpn-profile-row.vpn-selected { box-shadow: inset 3px 0 0 #2fb35d; }\
.vpn-ui .vpn-profile-title { font-weight:700; }\
.vpn-ui .vpn-muted { opacity:.72; font-size:.92em; }\
.vpn-ui .vpn-ping-ok { color:#66d489; font-weight:700; }\
.vpn-ui .vpn-ping-bad { color:#d46a6a; font-weight:700; }\
.vpn-ui .vpn-domain-test { margin:.5rem 0 1rem; }\
.vpn-ui .vpn-domain-test-row { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; margin:.5rem 0 1rem; }\
.vpn-ui .vpn-domain-test-row input { flex:1 1 24rem; min-width:14rem; }\
.vpn-ui .vpn-test-result { margin:0 0 1rem; }\
.vpn-ui .vpn-test-log { font-family:monospace; overflow-wrap:anywhere; }\
.vpn-ui .vpn-rule-search { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; margin:.5rem 0 1rem; }\
.vpn-ui .vpn-rule-search input { flex:1 1 24rem; min-width:14rem; }\
.vpn-ui .vpn-rule-search-summary { min-width:7rem; }\
.vpn-ui .vpn-rule-results { margin:0 0 1rem; max-height:14rem; overflow:auto; }\
.vpn-ui .vpn-rule-result-button { width:100%; text-align:left; font-family:monospace; overflow-wrap:anywhere; }\
.vpn-ui .vpn-rule-result-button mark { background:#2f6f3d; color:inherit; padding:0 .15rem; }\
.vpn-ui .vpn-rules-grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(280px, 1fr)); gap:1rem; }\
.vpn-ui .vpn-rules-grid textarea { width:100%; min-height:18rem; box-sizing:border-box; font-family:monospace; white-space:pre; }\
.vpn-ui .vpn-actions { display:flex; justify-content:flex-end; gap:.5rem; flex-wrap:wrap; margin-top:1rem; }\
.vpn-ui .vpn-service-row { display:flex; gap:.5rem; flex-wrap:wrap; margin:.25rem 0 1rem; }\
.vpn-ui .vpn-global-row { display:flex; justify-content:space-between; gap:1rem; flex-wrap:wrap; align-items:center; margin:.75rem 0 1rem; }\
.vpn-ui .vpn-global-state { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center; }\
.vpn-ui .vpn-device-row.vpn-device-direct { background:#173d25 !important; }\
.vpn-ui .vpn-device-row.vpn-device-direct > .td { background:transparent !important; }\
.vpn-ui .vpn-device-row.vpn-device-direct { box-shadow: inset 3px 0 0 #2fb35d; }\
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

function ruleLines(id) {
	var node = document.querySelector('#' + id);
	var value = node ? node.value : '';

	return value ? value.split(/\n/) : [];
}

function trimLine(value) {
	return (value || '').replace(/\r$/, '').replace(/^\s+/, '').replace(/\s+$/, '');
}

function highlightRuleMatch(value, query) {
	var lower = value.toLowerCase();
	var needle = query.toLowerCase();
	var pos = lower.indexOf(needle);

	if (!needle || pos < 0)
		return [ value ];

	return [
		value.slice(0, pos),
		E('mark', {}, value.slice(pos, pos + query.length)),
		value.slice(pos + query.length)
	];
}

function valueOrDash(value) {
	return value ? value : '-';
}

function upperLabel(value) {
	return value ? value.toUpperCase() : '-';
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
		return this.runAction(['refresh-pings'], _('Refreshing VPN status'));
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

	handleAddSubscription: function() {
		var input = document.querySelector('#vpn-subscription-url');
		var value = input ? input.value.trim() : '';

		if (!value) {
			ui.addNotification(null, E('p', {}, _('Paste an HTTPS subscription link first.')));
			return;
		}

		return this.runAction(['subscription-add', value], _('Importing subscription')).then(function() {
			if (input)
				input.value = '';
		});
	},

	handleSyncSubscription: function(id) {
		return this.runAction(['subscription-sync', id], _('Refreshing subscription'));
	},

	handleDeleteSubscription: function(id) {
		if (!confirm(_('Remove this subscription and its unused profiles?')))
			return;
		return this.runAction(['subscription-delete', id], _('Removing subscription'));
	},

	handleApplyAuto: function() {
		var failover = document.querySelector('#vpn-auto-failover');
		var periodic = document.querySelector('#vpn-auto-periodic');
		var hours = document.querySelector('#vpn-auto-hours');
		var pool = Array.prototype.slice.call(document.querySelectorAll('input[data-auto-profile]:checked'))
			.map(function(node) { return node.getAttribute('data-auto-profile'); })
			.join('\n');

		return this.runAction([
			'auto-config',
			failover && failover.checked ? '1' : '0',
			periodic && periodic.checked ? '1' : '0',
			hours ? hours.value : '12',
			pool
		], _('Saving automatic switching settings'));
	},

	handleTailscaleApply: function() {
		var server = document.querySelector('#vpn-tailscale-server');
		var hostname = document.querySelector('#vpn-tailscale-hostname');
		var key = document.querySelector('#vpn-tailscale-key');
		var routes = document.querySelector('#vpn-tailscale-routes');
		var exitNode = document.querySelector('#vpn-tailscale-exit');

		return this.runAction([
			'tailscale-up',
			server ? server.value.trim() : '',
			hostname ? hostname.value.trim() : '',
			key ? key.value.trim() : '',
			routes ? routes.value.trim() : '',
			exitNode && exitNode.checked ? '1' : '0'
		], _('Applying Tailscale settings'));
	},

	handleTailscaleRestart: function() {
		return this.runAction(['tailscale-restart'], _('Restarting Tailscale'));
	},

	handleTailscaleStop: function() {
		return this.runAction(['tailscale-stop'], _('Stopping Tailscale'));
	},

	handleTailscaleLogout: function() {
		if (!confirm(_('Log this router out of its current tailnet?')))
			return;
		return this.runAction(['tailscale-logout'], _('Logging out of Tailscale'));
	},

	handleUpdateCheck: function() {
		ui.showModal(_('Checking for updates'), [
			E('p', { 'class': 'spinning' }, _('Contacting the release server...'))
		]);
		return this.callHelper(['update-check']).then(function(data) {
			ui.hideModal();
			ui.showModal(_('VPN panel update'), [
				E('p', {}, data.available
					? _('Version %s is available. Installed: %s.').format(data.latest, data.current)
					: _('The VPN panel is up to date (%s).').format(data.current)),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('Close')),
					data.available ? ' ' : '',
					data.available ? E('button', {
						'class': 'btn cbi-button-positive',
						'disabled': isReadonlyView,
						'click': L.bind(this.handleUpdateApply, this)
					}, _('Install update')) : ''
				])
			]);
		}.bind(this)).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	handleUpdateApply: function() {
		ui.hideModal();
		ui.showModal(_('Installing VPN panel update'), [
			E('p', { 'class': 'spinning' }, _('Downloading, verifying, and installing the release bundle...'))
		]);
		return this.callHelper(['update-apply']).then(function(data) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('VPN panel updated to %s. Reloading...').format(data.current || '-')));
			window.setTimeout(function() { window.location.reload(); }, 1200);
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, err.message || err));
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

	searchRuleLines: function(query) {
		var needle = (query || '').toLowerCase();
		var sources = [
			{ id: 'vpn-direct-domains', label: _('Domains') },
			{ id: 'vpn-direct-ips', label: _('IP addresses') }
		];
		var matches = [];

		if (!needle)
			return matches;

		sources.forEach(function(source) {
			ruleLines(source.id).forEach(function(line, index) {
				var value = trimLine(line);

				if (!value)
					return;

				if (value.toLowerCase().indexOf(needle) < 0)
					return;

				matches.push({
					source: source.label,
					textarea: source.id,
					line: index + 1,
					value: value
				});
			});
		});

		return matches;
	},

	selectRuleLine: function(textareaId, lineNumber) {
		var textarea = document.querySelector('#' + textareaId);
		var lines, start = 0, i, end;

		if (!textarea)
			return;

		lines = textarea.value.split(/\n/);
		for (i = 0; i < lineNumber - 1 && i < lines.length; i++)
			start += lines[i].length + 1;

		end = start + (lines[lineNumber - 1] || '').replace(/\r$/, '').length;
		textarea.focus();
		textarea.setSelectionRange(start, end);

		if (lines.length > 1)
			textarea.scrollTop = Math.max(0, (textarea.scrollHeight - textarea.clientHeight) * ((lineNumber - 1) / (lines.length - 1)));
	},

	renderRuleSearchResults: function(matches, query) {
		var rows;

		if (!query)
			return [];

		if (!matches.length)
			return E('div', { 'class': 'vpn-rule-results vpn-muted' }, _('No matching rules.'));

		rows = matches.map(function(match) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, match.source),
				E('td', { 'class': 'td left' }, match.line),
				E('td', { 'class': 'td left' }, [
					E('button', {
						'class': 'cbi-button cbi-button-neutral vpn-rule-result-button',
						'click': L.bind(this.selectRuleLine, this, match.textarea, match.line)
					}, highlightRuleMatch(match.value, query))
				])
			]);
		}, this);

		return E('div', { 'class': 'vpn-rule-results' }, [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, _('List')),
					E('th', { 'class': 'th left' }, _('Line')),
					E('th', { 'class': 'th left' }, _('Rule'))
				])
			].concat(rows))
		]);
	},

	handleRuleSearch: function() {
		var input = document.querySelector('#vpn-rule-search');
		var results = document.querySelector('#vpn-rule-search-results');
		var summary = document.querySelector('#vpn-rule-search-summary');
		var query = input ? input.value.trim() : '';
		var matches = this.searchRuleLines(query);

		if (summary)
			dom.content(summary, query ? (matches.length == 1 ? _('1 match') : _('%s matches').format(matches.length)) : '');

		if (results)
			dom.content(results, this.renderRuleSearchResults(matches, query));
	},

	handleClearRuleSearch: function() {
		var input = document.querySelector('#vpn-rule-search');

		if (input)
			input.value = '';

		this.handleRuleSearch();
	},

	handleTestDomain: function() {
		var input = document.querySelector('#vpn-test-domain');
		var result = document.querySelector('#vpn-domain-test-result');
		var value = input ? input.value.trim() : '';

		if (!value) {
			ui.addNotification(null, E('p', {}, _('Enter a domain to test.')));
			return;
		}

		if (result)
			dom.content(result, E('p', { 'class': 'spinning' }, _('Testing route...')));

		return this.callHelper(['test-domain', value]).then(L.bind(function(data) {
			this.domainTest = data.test || null;
			if (result)
				dom.content(result, this.renderDomainTestResult(this.domainTest));
		}, this)).catch(function(err) {
			if (result)
				dom.content(result, E('div', { 'class': 'alert-message warning' }, err.message || err));
			else
				ui.addNotification(null, E('p', {}, err.message || err));
		});
	},

	handleTestDomainKeydown: function(ev) {
		if (ev.keyCode == 13) {
			ev.preventDefault();
			this.handleTestDomain();
		}
	},

	handleToggleXray: function(enabled) {
		var next = enabled ? 'off' : 'on';
		var title = enabled ? _('Disable VPN globally') : _('Enable VPN globally');
		var message = enabled
			? _('Stop transparent proxying and Xray for all devices?')
			: _('Start Xray and transparent proxying for all devices?');

		ui.showModal(title, [
			E('p', {}, message),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn ' + (enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
					'disabled': isReadonlyView,
					'click': L.bind(function() {
						this.runAction(['xray', next], title);
					}, this)
				}, enabled ? _('Disable') : _('Enable'))
			])
		]);
	},

	handleToggleDevice: function(device) {
		var next = device.vpn_disabled ? 'enable' : 'disable';
		var title = device.vpn_disabled ? _('Enable VPN for device') : _('Disable VPN for device');

		return this.runAction([
			'device',
			next,
			device.mac,
			device.ip
		], title);
	},

	load: function() {
		return this.callHelper(['status']);
	},

	renderGlobal: function(data) {
		var services = data.services || {};
		var enabled = !!services.vpn_enabled;

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Global VPN')),
			E('div', { 'class': 'vpn-global-row' }, [
				E('div', { 'class': 'vpn-global-state' }, [
					E('span', { 'class': 'label ' + (enabled ? 'notice' : 'warning') }, enabled ? _('Enabled') : _('Disabled')),
					E('span', { 'class': 'label' }, 'Xray: %s'.format(services.xray || '-')),
					E('span', { 'class': 'label' }, 'TProxy: %s'.format(services.transparent || '-'))
				]),
				E('button', {
					'class': 'cbi-button ' + (enabled ? 'cbi-button-negative' : 'cbi-button-positive'),
					'disabled': isReadonlyView,
					'click': L.bind(this.handleToggleXray, this, enabled)
				}, enabled ? _('Disable') : _('Enable'))
			])
		]);
	},

	renderDomainTestResult: function(test) {
		var route, routeClass, publicIps, profile, services, httpResult, ips;

		if (!test)
			return [];

		route = test.route || 'unknown';
		routeClass = route == 'direct' ? 'notice' : (route == 'vpn' ? 'warning' : '');
		publicIps = test.public_ips || {};
		profile = test.profile || {};
		services = test.services || {};
		ips = (test.resolved_ips || []).join(', ');
		httpResult = '%s %s in %ss'.format(
			(test.scheme || '').toUpperCase(),
			valueOrDash(test.http_code),
			valueOrDash(test.time_total)
		);

		return E('div', { 'class': 'vpn-test-result' }, [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Route')),
					E('td', { 'class': 'td left' }, [
						E('span', { 'class': 'label ' + routeClass }, upperLabel(route)),
						' ',
						E('span', { 'class': 'vpn-muted' }, 'Xray: %s'.format(valueOrDash(test.outbound)))
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Domain')),
					E('td', { 'class': 'td left' }, valueOrDash(test.domain))
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('HTTP test')),
					E('td', { 'class': 'td left' }, [
						httpResult,
						test.curl_error ? E('div', { 'class': 'vpn-muted' }, test.curl_error) : ''
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Resolved IPv4')),
					E('td', { 'class': 'td left' }, valueOrDash(ips))
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Public IPv4')),
					E('td', { 'class': 'td left' }, [
						E('span', { 'class': 'label' }, 'Direct'),
						' ',
						valueOrDash(publicIps.direct),
						' ',
						E('span', { 'class': 'label' }, 'VPN'),
						' ',
						valueOrDash(publicIps.vpn)
					])
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Selected profile')),
					E('td', { 'class': 'td left' }, '%s (%s, %s)'.format(
						valueOrDash(profile.name),
						valueOrDash(profile.endpoint),
						valueOrDash(profile.vps_ip)
					))
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Services')),
					E('td', { 'class': 'td left' }, 'Xray: %s, TProxy: %s'.format(
						valueOrDash(services.xray),
						valueOrDash(services.transparent)
					))
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('Access log')),
					E('td', { 'class': 'td left vpn-test-log' }, valueOrDash(test.access_log))
				])
			])
		]);
	},

	renderDomainTester: function() {
		return E('div', { 'class': 'vpn-domain-test' }, [
			E('div', { 'class': 'vpn-domain-test-row' }, [
				E('input', {
					'id': 'vpn-test-domain',
					'type': 'text',
					'placeholder': 'example.com',
					'keydown': L.bind(this.handleTestDomainKeydown, this)
				}),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleTestDomain')
				}, _('Test route'))
			]),
			E('div', { 'id': 'vpn-domain-test-result' }, this.renderDomainTestResult(this.domainTest))
		]);
	},

	renderProfileTable: function(data) {
		var profiles = data.profiles || [];
		var subscriptionNames = {};
		(data.subscriptions || []).forEach(function(subscription) {
			subscriptionNames[subscription.id] = subscription.name;
		});
		var rows = profiles.map(function(profile) {
			var selected = !!profile.selected;
			var pingClass = profile.ping == 'timeout' ? 'vpn-ping-bad' : (profile.ping == 'not tested' ? 'vpn-muted' : 'vpn-ping-ok');

			return E('tr', { 'class': 'tr vpn-profile-row' + (selected ? ' vpn-selected' : '') }, [
				E('td', { 'class': 'td left' }, [
					E('input', {
						'type': 'checkbox',
						'data-auto-profile': profile.id,
						'checked': profile.auto_pool ? '' : null,
						'disabled': isReadonlyView
					})
				]),
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
					E('div', { 'class': 'vpn-muted' }, profile.vps_ip || '-'),
					profile.source_id ? E('div', { 'class': 'vpn-muted' }, subscriptionNames[profile.source_id] || _('Subscription')) : ''
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

		return E('div', { 'class': 'vpn-table-wrap' }, E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th left' }, _('Auto')),
				E('th', { 'class': 'th left' }, _('Use')),
				E('th', { 'class': 'th left' }, _('Node')),
				E('th', { 'class': 'th left' }, _('Protocol')),
				E('th', { 'class': 'th left' }, _('Ping')),
				E('th', { 'class': 'th left' }, _('Status')),
				E('th', { 'class': 'th right' }, '')
			])
		].concat(rows.length ? rows : [
			E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': '7' }, _('No VLESS profiles saved.'))
			])
		])));
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

	renderSubscriptions: function(data) {
		var subscriptions = data.subscriptions || [];
		var rows = subscriptions.map(function(subscription) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, subscription.name || '-'),
				E('td', { 'class': 'td left' }, subscription.count || 0),
				E('td', { 'class': 'td left' }, subscription.updated || '-'),
				E('td', { 'class': 'td right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'disabled': isReadonlyView,
						'click': L.bind(this.handleSyncSubscription, this, subscription.id)
					}, _('Refresh')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'disabled': isReadonlyView,
						'click': L.bind(this.handleDeleteSubscription, this, subscription.id)
					}, _('Remove'))
				])
			]);
		}, this);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Subscriptions')),
			E('div', { 'class': 'vpn-muted vpn-section-note' }, _('Subscription URLs are stored with restricted permissions and are never displayed again.')),
			E('div', { 'class': 'vpn-add-row' }, [
				E('input', {
					'id': 'vpn-subscription-url',
					'type': 'password',
					'autocomplete': 'off',
					'placeholder': 'https://provider.example/sub/...',
					'disabled': isReadonlyView
				}),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleAddSubscription')
				}, _('Import'))
			]),
			E('div', { 'class': 'vpn-table-wrap' }, E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, _('Provider')),
					E('th', { 'class': 'th left' }, _('Profiles')),
					E('th', { 'class': 'th left' }, _('Last refresh')),
					E('th', { 'class': 'th right' }, '')
				])
			].concat(rows.length ? rows : [
				E('tr', { 'class': 'tr placeholder' }, [
					E('td', { 'class': 'td', 'colspan': '4' }, _('No subscriptions configured.'))
				])
			])))
		]);
	},

	renderAutoSwitch: function(data) {
		var auto = data.auto || {};
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Automatic server switching')),
			E('div', { 'class': 'vpn-muted vpn-section-note' }, _('Select eligible profiles in the Auto column above. Failover requires three failed one-minute TCP checks. Periodic optimization switches only for a substantial latency improvement.')),
			E('div', { 'class': 'vpn-settings-grid' }, [
				E('label', { 'class': 'vpn-check-row' }, [
					E('input', {
						'id': 'vpn-auto-failover',
						'type': 'checkbox',
						'checked': auto.failover ? '' : null,
						'disabled': isReadonlyView
					}),
					_('Fail over when the current server is unreachable')
				]),
				E('label', { 'class': 'vpn-check-row' }, [
					E('input', {
						'id': 'vpn-auto-periodic',
						'type': 'checkbox',
						'checked': auto.periodic ? '' : null,
						'disabled': isReadonlyView
					}),
					_('Periodically prefer a materially faster server')
				]),
				E('div', { 'class': 'vpn-setting' }, [
					E('label', { 'for': 'vpn-auto-hours' }, _('Optimization interval (hours)')),
					E('input', {
						'id': 'vpn-auto-hours',
						'type': 'number',
						'min': '6',
						'max': '168',
						'value': auto.periodic_hours || 12,
						'disabled': isReadonlyView
					})
				])
			]),
			E('div', { 'class': 'vpn-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleApplyAuto')
				}, _('Apply switching settings'))
			])
		]);
	},

	renderTailscale: function(data) {
		var tailscale = data.tailscale || {};
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Tailscale / Headscale')),
			E('div', { 'class': 'vpn-service-row' }, [
				E('span', { 'class': 'label ' + (tailscale.connected ? 'notice' : 'warning') }, tailscale.connected ? _('Connected') : _('Disconnected')),
				E('span', { 'class': 'label' }, 'IP: %s'.format(tailscale.ip || '-')),
				E('span', { 'class': 'label' }, 'Control: %s'.format(tailscale.control_url || '-'))
			]),
			E('div', { 'class': 'vpn-settings-grid' }, [
				E('div', { 'class': 'vpn-setting' }, [
					E('label', { 'for': 'vpn-tailscale-server' }, _('Login server')),
					E('input', {
						'id': 'vpn-tailscale-server',
						'type': 'text',
						'value': tailscale.control_url || 'https://login.tailscale.com',
						'disabled': isReadonlyView
					})
				]),
				E('div', { 'class': 'vpn-setting' }, [
					E('label', { 'for': 'vpn-tailscale-hostname' }, _('Node hostname')),
					E('input', {
						'id': 'vpn-tailscale-hostname',
						'type': 'text',
						'value': tailscale.hostname || '',
						'disabled': isReadonlyView
					})
				]),
				E('div', { 'class': 'vpn-setting' }, [
					E('label', { 'for': 'vpn-tailscale-key' }, _('Preauth key')),
					E('input', {
						'id': 'vpn-tailscale-key',
						'type': 'password',
						'autocomplete': 'off',
						'placeholder': tailscale.connected ? _('Optional while connected') : _('Required for first login'),
						'disabled': isReadonlyView
					})
				]),
				E('div', { 'class': 'vpn-setting' }, [
					E('label', { 'for': 'vpn-tailscale-routes' }, _('Advertise routes')),
					E('input', {
						'id': 'vpn-tailscale-routes',
						'type': 'text',
						'placeholder': '10.77.0.0/24',
						'disabled': isReadonlyView
					})
				]),
				E('label', { 'class': 'vpn-check-row' }, [
					E('input', {
						'id': 'vpn-tailscale-exit',
						'type': 'checkbox',
						'disabled': isReadonlyView
					}),
					_('Advertise this router as an exit node')
				])
			]),
			E('div', { 'class': 'vpn-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleTailscaleRestart')
				}, _('Restart')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': isReadonlyView || !tailscale.running,
					'click': ui.createHandlerFn(this, 'handleTailscaleStop')
				}, _('Stop service')),
				E('button', {
					'class': 'cbi-button cbi-button-negative',
					'disabled': isReadonlyView || !tailscale.connected,
					'click': ui.createHandlerFn(this, 'handleTailscaleLogout')
				}, _('Log out')),
				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleTailscaleApply')
				}, _('Apply / connect'))
			])
		]);
	},

	renderUpdate: function(data) {
		var update = data.update || {};
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Panel update')),
			E('div', { 'class': 'vpn-global-row' }, [
				E('div', { 'class': 'vpn-global-state' }, [
					E('span', { 'class': 'label' }, _('Installed version: %s').format(update.current || 'development')),
					E('span', { 'class': 'vpn-muted' }, _('Updates are downloaded as one release bundle and verified with SHA-256 before installation.'))
				]),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isReadonlyView,
					'click': ui.createHandlerFn(this, 'handleUpdateCheck')
				}, _('Check for updates'))
			])
		]);
	},

	renderRules: function(data) {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Direct routing rules')),
			this.renderDomainTester(),
			E('div', { 'class': 'vpn-rule-search' }, [
				E('input', {
					'id': 'vpn-rule-search',
					'type': 'search',
					'placeholder': _('Search rules'),
					'input': L.bind(this.handleRuleSearch, this)
				}),
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, 'handleClearRuleSearch')
				}, _('Clear')),
				E('span', { 'id': 'vpn-rule-search-summary', 'class': 'vpn-muted vpn-rule-search-summary' }, '')
			]),
			E('div', { 'id': 'vpn-rule-search-results' }),
			E('div', { 'class': 'vpn-rules-grid' }, [
				E('div', {}, [
					E('label', { 'class': 'cbi-value-title', 'for': 'vpn-direct-domains' }, _('Domains')),
					E('textarea', {
						'id': 'vpn-direct-domains',
						'spellcheck': 'false',
						'wrap': 'off',
						'disabled': isReadonlyView,
						'input': L.bind(this.handleRuleSearch, this)
					}, lines(data.domains))
				]),
				E('div', {}, [
					E('label', { 'class': 'cbi-value-title', 'for': 'vpn-direct-ips' }, _('IP addresses')),
					E('textarea', {
						'id': 'vpn-direct-ips',
						'spellcheck': 'false',
						'wrap': 'off',
						'disabled': isReadonlyView,
						'input': L.bind(this.handleRuleSearch, this)
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

	renderDevices: function(data) {
		var devices = data.devices || [];
		var rows = devices.map(function(device) {
			var disabled = !!device.vpn_disabled;

			return E('tr', { 'class': 'tr vpn-device-row' + (disabled ? ' vpn-device-direct' : '') }, [
				E('td', { 'class': 'td left' }, device.hostname || '-'),
				E('td', { 'class': 'td left' }, device.ip || '-'),
				E('td', { 'class': 'td left' }, device.mac || '-'),
				E('td', { 'class': 'td left' }, device.lease_remaining || '-'),
				E('td', { 'class': 'td left' }, [
					E('span', { 'class': 'label ' + (disabled ? 'notice' : '') }, disabled ? _('Direct') : _('VPN'))
				]),
				E('td', { 'class': 'td right' }, [
					E('button', {
						'class': 'cbi-button ' + (disabled ? 'cbi-button-positive' : 'cbi-button-negative'),
						'disabled': isReadonlyView,
						'click': L.bind(this.handleToggleDevice, this, device)
					}, disabled ? _('Enable') : _('Disable'))
				])
			]);
		}, this);

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Device VPN status')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, _('Hostname')),
					E('th', { 'class': 'th left' }, _('IPv4 address')),
					E('th', { 'class': 'th left' }, _('MAC address')),
					E('th', { 'class': 'th left' }, _('Lease time remaining')),
					E('th', { 'class': 'th left' }, _('Status')),
					E('th', { 'class': 'th right' }, '')
				])
			].concat(rows.length ? rows : [
				E('tr', { 'class': 'tr placeholder' }, [
					E('td', { 'class': 'td', 'colspan': '6' }, _('There are no active DHCP leases.'))
				])
			]))
		]);
	},

	renderBody: function(data) {
		return [
			this.renderGlobal(data),
			this.renderUpdate(data),
			this.renderSubscriptions(data),
			this.renderProfiles(data),
			this.renderAutoSwitch(data),
			this.renderTailscale(data),
			this.renderRules(data),
			this.renderDevices(data)
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
