'use strict';
'require baseclass';

var STYLE_ID = 'router-scripts-footer-style';
var ROW_ID = 'router-scripts-footer-info';

function humanize(value) {
	return String(value || 'unknown').replace(/-/g, ' ');
}

function ensureStyle() {
	if (document.getElementById(STYLE_ID))
		return;

	var style = document.createElement('style');
	style.id = STYLE_ID;
	style.textContent = '\
#router-scripts-footer-info { display:flex; align-items:center; justify-content:space-between; gap:.7rem 1.25rem; flex-wrap:wrap; width:100%; box-sizing:border-box; margin:0 0 .8rem; padding:0 0 .8rem; border-bottom:1px solid rgba(127,127,127,.28); }\
#router-scripts-footer-info .router-footer-product { display:flex; align-items:baseline; gap:.5rem; flex-wrap:wrap; }\
#router-scripts-footer-info .router-footer-name { font-weight:700; letter-spacing:.01em; opacity:.96; }\
#router-scripts-footer-info .router-footer-version { font-variant-numeric:tabular-nums; opacity:.75; }\
#router-scripts-footer-info .router-footer-meta { display:flex; gap:.45rem; flex-wrap:wrap; }\
#router-scripts-footer-info .router-footer-pill { display:inline-flex; align-items:center; border:1px solid rgba(127,127,127,.32); border-radius:999px; padding:.16rem .55rem; line-height:1.45; background:rgba(127,127,127,.08); }\
@media (max-width:600px) { #router-scripts-footer-info { align-items:flex-start; } #router-scripts-footer-info .router-footer-meta { width:100%; } }\
';
	document.head.appendChild(style);
}

function render(metadata, attempts) {
	var footer, row;
	metadata = metadata || {};

	if (metadata.footer_enabled === false) {
		row = document.getElementById(ROW_ID);
		if (row)
			row.remove();
		return;
	}

	footer = document.querySelector('footer');
	if (!footer) {
		if (attempts > 0)
			window.setTimeout(function() { render(metadata, attempts - 1); }, 100);
		return;
	}

	ensureStyle();
	row = document.getElementById(ROW_ID);
	if (!row) {
		row = document.createElement('div');
		row.id = ROW_ID;
		footer.insertBefore(row, footer.firstChild);
	}

	row.replaceChildren(
		E('span', { 'class': 'router-footer-product' }, [
			E('span', { 'class': 'router-footer-name' }, _('Router Scripts')),
			E('span', { 'class': 'router-footer-version' }, metadata.version ? 'v' + metadata.version : _('version unavailable'))
		]),
		E('span', { 'class': 'router-footer-meta' }, [
			E('span', { 'class': 'router-footer-pill' }, _('Support: %s').format(humanize(metadata.support_level))),
			E('span', { 'class': 'router-footer-pill' }, _('Registration: %s').format(humanize(metadata.registration_state)))
		])
	);
}

return baseclass.extend({
	apply: function(metadata) {
		window.setTimeout(function() { render(metadata, 20); }, 0);
	}
});
