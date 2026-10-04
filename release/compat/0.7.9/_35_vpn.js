'use strict';
'require baseclass';

/* PREMIER_ROUTER_079_COMPAT_NOOP
 * The published 0.7.9 worker checks only for this filename after install.
 * Returning null keeps the LuCI 24.10 include container hidden, so the
 * canonical 35_vpn.js remains the only visible status card.
 */
return baseclass.extend({
	load: function() {
		return null;
	},

	render: function() {
		return null;
	}
});
