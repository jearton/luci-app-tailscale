/* SPDX-License-Identifier: GPL-3.0-only
 *
 * Copyright (C) 2024 asvow
 */

'use strict';
'require form';
'require fs';
'require network';
'require poll';
'require rpc';
'require uci';
'require view';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

async function getInterfaceSubnets(interfaces = ['lan', 'wan']) {
	const networks = await network.getNetworks();
	return [...new Set(
		networks
			.filter(ifc => interfaces.includes(ifc.getName()))
			.flatMap(ifc => ifc.getIPAddrs())
			.filter(addr => addr.includes('/'))
			.map(addr => {
				const [ip, cidr] = addr.split('/');
				const ipParts = ip.split('.').map(Number);
				const mask = ~((1 << (32 - parseInt(cidr))) - 1);
				const subnetParts = ipParts.map((part, i) => (part & (mask >> (24 - i * 8))) & 255);
				return `${subnetParts.join('.')}/${cidr}`;
			})
	)];
}

async function getStatus() {
	const status = {
		isRunning: false,
		backendState: undefined,
		authURL: undefined,
		displayName: undefined,
		onlineExitNodes: [],
		peers: [],
		subnetRoutes: []
	};
	const res = await callServiceList('tailscale');
	try {
		status.isRunning = res['tailscale']['instances']['instance1']['running'];
	} catch (e) {
		return status;
	}
	const tailscaleRes = await fs.exec("/usr/sbin/tailscale", ["status", "--json"]);
	const tailscaleStatus = JSON.parse(tailscaleRes.stdout.replace(/("\w+"):\s*(\d+)/g, '$1:"$2"'));
	if (!tailscaleStatus.AuthURL && tailscaleStatus.BackendState === "NeedsLogin") {
		fs.exec("/usr/sbin/tailscale", ["login"]);
	}
	status.backendState = tailscaleStatus.BackendState;
	status.authURL = tailscaleStatus.AuthURL;
	status.displayName = (status.backendState === "Running") ? tailscaleStatus.User[tailscaleStatus.Self.UserID].DisplayName : undefined;
	if (tailscaleStatus.Peer) {
		status.peers = Object.values(tailscaleStatus.Peer)
			.map(peer => {
				const ip = Array.isArray(peer.TailscaleIPs) ? (peer.TailscaleIPs[0] || '') : '';
				const dnsName = (peer.DNSName || '').replace(/\.$/, '');
				const label = [
					peer.HostName || dnsName || ip,
					ip,
					peer.Online ? _('Online') : _('Offline')
				].filter(Boolean).join('    ');

				return {
					name: peer.HostName || dnsName || ip,
					label: label
				};
			})
			.filter(peer => peer.name);
		status.onlineExitNodes = Object.values(tailscaleStatus.Peer)
			.flatMap(peer => (peer.ExitNodeOption && peer.Online) ? [peer.HostName] : []);
		status.subnetRoutes = Object.values(tailscaleStatus.Peer)
			.flatMap(peer => peer.PrimaryRoutes || []);
	}
	return status;
}

function renderStatus(isRunning) {
	const spanTemp = '<em><span style="color:%s"><strong>%s %s</strong></span></em>';
	let renderHTML;
	if (isRunning) {
		renderHTML = String.format(spanTemp, 'green', _('Tailscale'), _('RUNNING'));
	} else {
		renderHTML = String.format(spanTemp, 'red', _('Tailscale'), _('NOT RUNNING'));
	}

	return renderHTML;
}

function renderLogin(loginStatus, authURL, displayName) {
	const spanTemp = '<span style="color:%s">%s</span>';
	let renderHTML;
	if (loginStatus === "NeedsLogin") {
		renderHTML = String.format('<a href="%s" target="_blank">%s</a>', authURL, _('Need to log in'));
	} else if (loginStatus === "Running") {
		renderHTML = String.format('<a href="%s" target="_blank">%s</a>', 'https://login.tailscale.com/admin/machines', displayName);
		renderHTML += String.format('<br><a style="color:green" id="logout_button">%s</a>', _('Log out and Unbind'));
	} else {
		renderHTML = String.format(spanTemp, 'orange', _('NOT RUNNING'));
	}

	return renderHTML;
}

function toList(value) {
	if (!value)
		return [];

	if (Array.isArray(value))
		return value;

	return String(value).trim().split(/\s+/).filter(Boolean);
}

function parseKeyValues(stdout) {
	const out = {};
	String(stdout || '').split(/\n/).forEach(function(line) {
		const idx = line.indexOf('=');
		if (idx > 0)
			out[line.slice(0, idx)] = line.slice(idx + 1);
	});
	return out;
}

function renderCheck(value) {
	const ok = value === 'pass';
	return E('span', { style: 'color:' + (ok ? 'green' : 'red') }, ok ? _('Pass') : _('Fail'));
}

function hasFormListValue(option, section_id) {
	return toList(option.formvalue(section_id)).map(function(value) {
		return String(value || '').trim();
	}).filter(Boolean).length > 0;
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('tailscale'),
			getStatus(),
			getInterfaceSubnets(),
			fs.exec("/usr/sbin/tailscale_adguard_dns_switch", ["--preflight"]).catch(function(e) {
				let stdout = e && e.stdout ? e.stdout : '';
				const error = e && (e.message || e.stderr || e) || 'preflight command failed';
				if (stdout && stdout.charAt(stdout.length - 1) !== '\n')
					stdout += '\n';
				return { stdout: stdout + 'ready=fail\nerror=' + String(error).replace(/\n/g, ' ') + '\n' };
			})
		]);
	},

	render(data) {
		let m, s, o;
		const statusData = data[1];
		const interfaceSubnets = data[2];
		const onlineExitNodes = statusData.onlineExitNodes;
		const peers = statusData.peers;
		const subnetRoutes = statusData.subnetRoutes;
		const hasAuthKey = !!uci.get('tailscale', 'settings', 'authkey');
		const savedKeepalivePeers = toList(uci.get('tailscale', 'settings', 'keepalive_peers'));
		const adguardPreflight = parseKeyValues((data[3] || {}).stdout);
		const hasAdguardPassword = !!uci.get('tailscale', 'settings', 'adguard_password');
		const adguardEnvironmentChecks = [
			'adguard_process',
			'port_53_adguard',
			'dhcp_advertises_lan_dns',
			'adguard_api'
		];

		m = new form.Map('tailscale', _('Tailscale'), _('Tailscale is a cross-platform and easy to use virtual LAN.'));
		let acceptDnsOption;

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function () {
			poll.add(async function() {
				const res = await getStatus();
				const service_view = document.getElementById("service_status");
				const login_view = document.getElementById("login_status_div");
				service_view.innerHTML = renderStatus(res.isRunning);
				login_view.innerHTML = renderLogin(res.backendState, res.authURL, res.displayName);
				const logoutButton = document.getElementById('logout_button');
				if (logoutButton) {
					logoutButton.onclick = function() {
						if (confirm(_('Are you sure you want to log out and unbind the current device?'))) {
							fs.exec("/usr/sbin/tailscale", ["logout"]);
						}
					}
				}
			});

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, _('Collecting data ...'))
			]);
		}

		s = m.section(form.NamedSection, 'settings', 'config');
		s.tab('basic', _('Basic Settings'));

		o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('basic', form.DummyValue, 'login_status', _('Login Status'));
		o.depends('enabled', '1');
		o.renderWidget = function(section_id, option_id) {
			return E('div', { 'id': 'login_status_div' }, _('Collecting data ...'));
		};

		o = s.taboption('basic', form.Value, 'port', _('Port'), _('Set the Tailscale port number.'));
		o.datatype = 'port';
		o.default = '41641';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'config_path', _('Workdir'), _('The working directory contains config files, audit logs, and runtime info.'));
		o.default = '/etc/tailscale';
		o.rmempty = false;

		o = s.taboption('basic', form.ListValue, 'fw_mode', _('Firewall Mode'));
		o.value('nftables', 'nftables');
		o.value('iptables', 'iptables');
		o.default = 'nftables';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'log_stdout', _('StdOut Log'), _('Logging program activities.'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'log_stderr', _('StdErr Log'), _('Logging program errors and exceptions.'));
		o.default = o.enabled;
		o.rmempty = false;

		s.tab('advance', _('Advanced Settings'));

		o = s.taboption('advance', form.Flag, 'accept_routes', _('Accept Routes'), _('Accept subnet routes that other nodes advertise.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advance', form.Value, 'hostname', _('Device Name'), _("Leave blank to use the device's hostname."));
		o.default = '';
		o.rmempty = true;

		acceptDnsOption = s.taboption('advance', form.Flag, 'accept_dns', _('Accept DNS'), _('Accept DNS configuration from the Tailscale admin console.'));
		acceptDnsOption.default = acceptDnsOption.enabled;
		acceptDnsOption.rmempty = false;

		o = s.taboption('advance', form.Flag, 'advertise_exit_node', _('Exit Node'), _('Offer to be an exit node for outbound internet traffic from the Tailscale network.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advance', form.ListValue, 'exit_node', _('Online Exit Nodes'), _('Select an online machine name to use as an exit node.'));
		if (onlineExitNodes.length > 0) {
			o.optional = true;
			onlineExitNodes.forEach(function(node) {
				o.value(node, node);
			});
		} else {
			o.value('', _('No Available Exit Nodes'));
			o.readonly = true;
		}
		o.default = '';
		o.depends('advertise_exit_node', '0');
		o.rmempty = true;

		o = s.taboption('advance', form.DynamicList, 'advertise_routes', _('Expose Subnets'), _('Expose physical network routes into Tailscale, e.g. <code>10.0.0.0/24</code>.'));
		if (interfaceSubnets.length > 0) {
			interfaceSubnets.forEach(function(subnet) {
				o.value(subnet, subnet);
			});
		}
		o.default = '';
		o.rmempty = true;

		o = s.taboption('advance', form.Flag, 'disable_snat_subnet_routes', _('Site To Site'), _('Use site-to-site layer 3 networking to connect subnets on the Tailscale network.'));
		o.default = o.disabled;
		o.depends('accept_routes', '1');
		o.rmempty = false;

		o = s.taboption('advance', form.DynamicList, 'subnet_routes', _('Subnet Routes'), _('Select subnet routes advertised by other nodes in Tailscale network.'));
		if (subnetRoutes.length > 0) {
			subnetRoutes.forEach(function(route) {
				o.value(route, route);
			});
		} else {
			o.value('', _('No Available Subnet Routes'));
			o.readonly = true;
		}
		o.default = '';
		o.depends('disable_snat_subnet_routes', '1');
		o.rmempty = true;

		o = s.taboption('advance', form.MultiValue, 'access', _('Access Control'));
		o.value('ts_ac_lan', _('Tailscale access LAN'));
		o.value('ts_ac_wan', _('Tailscale access WAN'));
		o.value('lan_ac_ts', _('LAN access Tailscale'));
		o.value('wan_ac_ts', _('WAN access Tailscale'));
		o.default = "ts_ac_lan ts_ac_wan lan_ac_ts";
		o.rmempty = true;

		o = s.taboption('advance', form.Flag, 'keepalive_enabled', _('Peer Keepalive'), _('Periodically send lightweight Tailscale pings to selected peers.'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.taboption('advance', form.MultiValue, 'keepalive_peers', _('Keepalive Peers'), _('Select peers that should be kept warm with periodic Tailscale pings.'));
		const keepalivePeerNames = {};
		peers.forEach(function(peer) {
			keepalivePeerNames[peer.name] = true;
			o.value(peer.name, peer.label);
		});
		savedKeepalivePeers.forEach(function(peer) {
			if (!keepalivePeerNames[peer]) {
				keepalivePeerNames[peer] = true;
				o.value(peer, [peer, _('Not found')].join('    '));
			}
		});
		if (Object.keys(keepalivePeerNames).length === 0) {
			o.value('', _('No Available Peers'));
			o.readonly = true;
		} else {
			o.default = savedKeepalivePeers.join(' ');
		}
		o.depends('keepalive_enabled', '1');
		o.rmempty = true;

		o = s.taboption('advance', form.Value, 'keepalive_interval', _('Keepalive Interval'), _('Seconds between keepalive probes.'));
		o.datatype = 'uinteger';
		o.default = '20';
		o.depends('keepalive_enabled', '1');
		o.rmempty = false;

		o = s.taboption('advance', form.Value, 'keepalive_failure_log_interval', _('Failure Log Interval'), _('Seconds between repeated failure log messages for the same peer.'));
		o.datatype = 'uinteger';
		o.default = '300';
		o.depends('keepalive_enabled', '1');
		o.rmempty = false;

		s.tab('adguard_dns', _('AdGuard DNS'));
		let adguardApiUrlOption, adguardUsernameOption, adguardPasswordOption;
		let adguardDefaultUpstreamsOption, adguardTailnetUpstreamsOption, adguardHealthDomainOption, adguardHealthExpectedIpsOption;
		const adguardCredentialsChanged = function(section_id) {
			const currentApiUrl = String(uci.get('tailscale', 'settings', 'adguard_api_url') || 'http://127.0.0.1:3000');
			const currentUsername = String(uci.get('tailscale', 'settings', 'adguard_username') || '');
			const formApiUrl = String(adguardApiUrlOption.formvalue(section_id) || 'http://127.0.0.1:3000').trim();
			const formUsername = String(adguardUsernameOption.formvalue(section_id) || '').trim();
			const formPassword = String(adguardPasswordOption.formvalue(section_id) || '').trim();

			return formApiUrl !== currentApiUrl || formUsername !== currentUsername || !!formPassword;
		};

		adguardApiUrlOption = s.taboption('adguard_dns', form.Value, 'adguard_api_url', _('AdGuard API URL'));
		adguardApiUrlOption.default = 'http://127.0.0.1:3000';
		adguardApiUrlOption.rmempty = false;

		adguardUsernameOption = s.taboption('adguard_dns', form.Value, 'adguard_username', _('AdGuard Username'));
		adguardUsernameOption.default = '';
		adguardUsernameOption.rmempty = true;

		adguardPasswordOption = s.taboption('adguard_dns', form.Value, 'adguard_password', _('AdGuard Password'));
		adguardPasswordOption.password = true;
		adguardPasswordOption.default = '';
		adguardPasswordOption.rmempty = true;
		adguardPasswordOption.placeholder = hasAdguardPassword ? _('Configured; leave blank to keep existing value.') : '';
		adguardPasswordOption.description = hasAdguardPassword ? _('Configured; leave blank to keep existing value.') : '';
		adguardPasswordOption.cfgvalue = function() {
			return '';
		};
		adguardPasswordOption.write = function(section_id, value) {
			value = (value || '').trim();
			if (value)
				return uci.set('tailscale', section_id, 'adguard_password', value);
		};
		adguardPasswordOption.remove = function() {};

		o = s.taboption('adguard_dns', form.DummyValue, '_adguard_dns_status', _('Status'));
		o.renderWidget = function() {
			return E('div', { class: 'table' }, [
				E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('AdGuard process')), E('div', { class: 'td' }, renderCheck(adguardPreflight.adguard_process))]),
				E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('Port 53 is AdGuard')), E('div', { class: 'td' }, renderCheck(adguardPreflight.port_53_adguard))]),
				E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('LAN DHCP advertises this router as DNS')), E('div', { class: 'td' }, renderCheck(adguardPreflight.dhcp_advertises_lan_dns))]),
				E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('AdGuard API')), E('div', { class: 'td' }, renderCheck(adguardPreflight.adguard_api))]),
				E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('Tailscale Accept DNS')), E('div', { class: 'td' }, renderCheck(adguardPreflight.accept_dns))]),
				E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('Tailnet DNS health check')), E('div', { class: 'td' }, renderCheck(adguardPreflight.health_check))])
			]);
		};

		o = s.taboption('adguard_dns', form.Flag, 'adguard_dns_switch_enabled', _('Enable AdGuard DNS Auto Switch'), _('Only enable when all status checks pass.'));
		o.default = o.disabled;
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (value !== '1')
				return true;

			if (!String(adguardHealthDomainOption.formvalue(section_id) || '').trim())
				return _('Health Check Domain is required before enabling AdGuard DNS auto switch.');

			if (!hasFormListValue(adguardHealthExpectedIpsOption, section_id))
				return _('At least one Expected Health IP is required before enabling AdGuard DNS auto switch.');

			if (!hasFormListValue(adguardDefaultUpstreamsOption, section_id))
				return _('At least one Default Upstream is required before enabling AdGuard DNS auto switch.');

			if (!hasFormListValue(adguardTailnetUpstreamsOption, section_id))
				return _('At least one Tailnet Upstream is required before enabling AdGuard DNS auto switch.');

			if (acceptDnsOption.formvalue(section_id) !== '1')
				return _('Accept DNS must be enabled before enabling AdGuard DNS auto switch.');

			for (let i = 0; i < adguardEnvironmentChecks.length; i++) {
				const check = adguardEnvironmentChecks[i];
				if (adguardPreflight[check] !== 'pass' && !(check === 'adguard_api' && adguardCredentialsChanged(section_id)))
					return _('AdGuard DNS auto switch cannot be enabled until every environment status check passes.');
			}

			return true;
		};

		adguardDefaultUpstreamsOption = s.taboption('adguard_dns', form.DynamicList, 'adguard_default_upstreams', _('Default Upstreams'), _('Used when Tailnet DNS is unhealthy.'));
		adguardDefaultUpstreamsOption.default = '';
		adguardDefaultUpstreamsOption.rmempty = true;

		adguardTailnetUpstreamsOption = s.taboption('adguard_dns', form.DynamicList, 'adguard_tailnet_upstreams', _('Tailnet Upstreams'), _('Added when Tailnet DNS is healthy.'));
		adguardTailnetUpstreamsOption.default = '';
		adguardTailnetUpstreamsOption.rmempty = true;

		adguardHealthDomainOption = s.taboption('adguard_dns', form.Value, 'adguard_health_domain', _('Health Check Domain'));
		adguardHealthDomainOption.rmempty = true;

		o = s.taboption('adguard_dns', form.Value, 'adguard_health_dns', _('Health Check DNS Server'));
		o.default = '100.100.100.100';
		o.rmempty = false;

		adguardHealthExpectedIpsOption = s.taboption('adguard_dns', form.DynamicList, 'adguard_health_expected_ips', _('Expected Health IPs'));
		adguardHealthExpectedIpsOption.default = '';
		adguardHealthExpectedIpsOption.rmempty = true;

		o = s.taboption('adguard_dns', form.Value, 'adguard_check_interval', _('Check Interval'));
		o.datatype = 'uinteger';
		o.default = '10';
		o.rmempty = false;

		o = s.taboption('adguard_dns', form.Value, 'adguard_success_threshold', _('Success Threshold'));
		o.datatype = 'uinteger';
		o.default = '2';
		o.rmempty = false;

		o = s.taboption('adguard_dns', form.Value, 'adguard_failure_threshold', _('Failure Threshold'));
		o.datatype = 'uinteger';
		o.default = '2';
		o.rmempty = false;

		o = s.taboption('adguard_dns', form.Flag, 'adguard_clear_cache', _('Clear AdGuard Cache After Switch'));
		o.default = o.enabled;
		o.rmempty = false;

		s.tab('extra', _('Extra Settings'));

		o = s.taboption('extra', form.DynamicList, 'flags', _('Additional Flags'),
			String.format(
				_('List of extra flags. Format: --flags=value, e.g. <code>--exit-node=10.0.0.1</code>. <br> %s for enabling settings upon the initiation of Tailscale.'),
				'<a href="https://tailscale.com/kb/1241/tailscale-up" target="_blank">' + _('Available flags') + '</a>'
			)
		);
		o.default = '';
		o.rmempty = true;

		s = m.section(form.NamedSection, 'settings', 'config');
		s.title = _('Custom Server Settings');
		s.description = String.format(_('Use %s to deploy a private server.'), '<a href="https://github.com/juanfont/headscale" target="_blank">headscale</a>');

		o = s.option(form.Value, 'login_server', _('Server Address'));
		o.default = '';
		o.rmempty = true;

		o = s.option(form.Value, 'authkey', _('Auth Key'));
		o.password = true;
		o.default = '';
		o.rmempty = true;
		o.placeholder = hasAuthKey ? _('Configured; leave blank to keep existing value.') : '';
		o.description = hasAuthKey ? _('Configured; leave blank to keep existing value.') : '';
		o.cfgvalue = function() {
			return '';
		};
		o.write = function(section_id, value) {
			value = (value || '').trim();
			if (value)
				return uci.set('tailscale', section_id, 'authkey', value);
		};
		o.remove = function() {};

		return m.render();
	}
});
