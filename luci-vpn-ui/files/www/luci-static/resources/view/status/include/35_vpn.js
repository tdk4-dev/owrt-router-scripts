'use strict';
'require baseclass';
'require fs';

var helper = '/usr/sbin/vpn-ui-readonly';

function parseResponse(res) {
	var output = (res && res.stdout) ? res.stdout.trim() : '';
	var data = JSON.parse(output || '{}');
	if (!data.ok)
		throw new Error(data.error || _('VPN status is unavailable.'));
	return data;
}

return baseclass.extend({
	title: _('VPN service'),

	load: function() {
		return fs.exec(helper, ['vpn-summary']).then(parseResponse);
	},

	render: function(data) {
		var state = data.working
			? E('span', { 'class': 'label notice' }, _('Working'))
			: E('span', { 'class': 'label warning' }, _('Not working'));
		var fields = [
			_('Service status'), state,
			_('Selected configuration'), data.selected_name || '-',
			_('Server endpoint'), data.endpoint || '-',
			_('Server IP'), data.ip || '-',
			_('Direct domain rules'), String(data.direct_domain_rules || 0),
			_('Selected server ping'), data.ping || _('Not tested')
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
