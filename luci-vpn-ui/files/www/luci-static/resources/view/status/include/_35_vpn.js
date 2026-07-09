'use strict';
'require baseclass';
'require fs';

var helper = '/usr/sbin/vpn-ui';

function parseResponse(res) {
	var output = (res && res.stdout) ? res.stdout.trim() : '';
	var data = JSON.parse(output || '{}');
	if (!data.ok)
		throw new Error(data.error || _('VPN status is unavailable.'));
	return data;
}

return baseclass.extend({
	title: _('Router Scripts and VPN service'),

	load: function() {
		return Promise.all([
			fs.exec(helper, ['vpn-summary']).then(parseResponse).catch(function() {
				return { working: false };
			}),
			fs.exec(helper, ['footer-info']).then(parseResponse)
		]).then(function(result) {
			return { vpn: result[0], metadata: result[1] };
		});
	},

	render: function(data) {
		var vpn = data.vpn || {};
		var metadata = data.metadata || {};
		var state = vpn.working
			? E('span', { 'class': 'label notice' }, _('Working'))
			: E('span', { 'class': 'label warning' }, _('Not working'));
		var fields = [
			_('Router Scripts'), metadata.footer_label || '-',
			_('Installation method'), metadata.install_method || '-',
			_('Support level'), metadata.support_level || '-',
			_('Registration state'), metadata.registration_state || '-',
			_('Router ID'), metadata.router_id_short || '-',
			_('Service status'), state,
			_('Selected configuration'), vpn.selected_name || '-',
			_('Server endpoint'), vpn.endpoint || '-',
			_('Server IP'), vpn.ip || '-',
			_('Direct domain rules'), String(vpn.direct_domain_rules || 0),
			_('Selected server ping'), vpn.ping || _('Not tested')
		];
		var table = E('table', { 'class': 'table' });

		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
				E('td', { 'class': 'td left' }, [ fields[i + 1] ])
			]));
		}
		return table;
	}
});
