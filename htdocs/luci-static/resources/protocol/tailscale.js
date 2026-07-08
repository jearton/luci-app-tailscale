'use strict';
'require network';

network.registerPatternVirtual(/^tailscale0$/);

return network.registerProtocol('tailscale', {
	getI18n: function() {
		return _('Tailscale');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'tailscale0';
	},

	getPackageName: function() {
		return 'luci-app-tailscale';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) === this.getIfname());
	}
});
