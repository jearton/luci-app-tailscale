/* SPDX-License-Identifier: GPL-3.0-only
 *
 * Copyright (C) 2026
 */

'use strict';
'require dom';
'require fs';
'require poll';
'require view';

function formatLastSeen(value) {
	if (!value)
		return '-';

	value = String(value);
	if (value.indexOf('0001-01-01') === 0)
		return '-';

	var date = new Date(value);
	if (isNaN(date.getTime()))
		return value;

	return date.toLocaleString();
}

function parseStatus(stdout) {
	var parsed = JSON.parse(String(stdout || '{}'));
	var peerEntries = parsed && parsed.Peer ? parsed.Peer : {};
	var peers = [];

	Object.keys(peerEntries).forEach(function(peerId) {
		var peer = peerEntries[peerId] || {};
		var ip = Array.isArray(peer.TailscaleIPs) ? (peer.TailscaleIPs[0] || '') : '';
		var dnsName = String(peer.DNSName || '').replace(/\.$/, '');
		var shortDnsName = dnsName ? dnsName.split('.')[0] : '';
		var hostName = String(peer.HostName || '');
		var displayName = (shortDnsName && hostName && shortDnsName !== hostName)
			? shortDnsName + ' (' + hostName + ')'
			: (shortDnsName || hostName || dnsName || ip || peerId);
		var routes = Array.isArray(peer.PrimaryRoutes) ? peer.PrimaryRoutes.filter(Boolean) : [];

		peers.push({
			id: peerId,
			name: displayName,
			ip: ip,
			online: !!peer.Online,
			lastSeen: formatLastSeen(peer.LastSeen),
			exitNode: !!peer.ExitNodeOption,
			routes: routes,
			hasSubnetRoutes: routes.length > 0,
			probeTarget: ip || hostName || dnsName || shortDnsName
		});
	});

	peers.sort(function(a, b) {
		return String(a.name || '').localeCompare(String(b.name || ''));
	});

	return peers;
}

function parseProbeResult(stdout, errorMessage) {
	var fallback = {
		ok: false,
		path: 'failed',
		summary: errorMessage || _('Probe failed'),
		raw: ''
	};

	if (!stdout)
		return fallback;

	try {
		var parsed = JSON.parse(String(stdout));
		return parsed && typeof parsed === 'object' ? parsed : fallback;
	} catch (e) {
		fallback.summary = errorMessage || String(e.message || e);
		return fallback;
	}
}

function stripProbeSummary(path, summary) {
	summary = String(summary || '').trim();

	if (!summary)
		return '';

	if (path === 'direct')
		return summary.replace(/^direct\b[\s:-]*/i, '');

	if (path === 'derp')
		return summary.replace(/^DERP\b[\s:-]*/i, '');

	return summary;
}

function renderProbeResult(result) {
	if (!result)
		return E('span', { style: 'color:#94a3b8' }, _('Not probed'));

	var path = result.path || 'unknown';
	var label = path === 'direct' ? _('Direct')
		: (path === 'derp' ? _('DERP')
			: (path === 'failed' ? _('Failed') : _('Unknown')));
	var color = path === 'direct' ? '#166534'
		: (path === 'derp' ? '#a16207'
			: (path === 'failed' ? '#b91c1c' : '#475569'));
	var summary = stripProbeSummary(path, result.summary);

	return E('span', { style: 'color:%s'.format(color) }, [
		E('strong', {}, label),
		summary ? ' - ' + summary : ''
	]);
}

function renderBadge(text) {
	return E('span', {
		style: 'display:inline-block;margin:0 4px 4px 0;padding:1px 6px;border-radius:3px;background:#eef2f7;color:#334155;font-size:12px;line-height:1.4'
	}, text);
}

function renderStatusLabel(online) {
	return E('span', {
		style: 'font-weight:600;color:%s'.format(online ? '#166534' : '#64748b')
	}, online ? _('Online') : _('Offline'));
}

function renderRoleBadges(peer) {
	var badges = [];

	if (peer.exitNode)
		badges.push(renderBadge(_('Exit node')));

	if (peer.hasSubnetRoutes)
		badges.push(renderBadge(_('Advertising subnets')));

	return badges.length ? badges : '-';
}

async function loadPeerState() {
	try {
		var res = await fs.exec('/usr/sbin/tailscale', ['status', '--json']);
		var code = Number(res && res.code);

		if (Number.isFinite(code) && code !== 0) {
			var statusError = String((res && (res.stderr || res.stdout || res.message)) || _('Unable to load Tailscale peer status')).trim();

			return {
				ok: false,
				peers: [],
				error: statusError || _('Unable to load Tailscale peer status')
			};
		}

		return {
			ok: true,
			peers: parseStatus(res.stdout),
			error: ''
		};
	} catch (e) {
		return {
			ok: false,
			peers: [],
			error: String((e && (e.message || e.stderr || e.stdout)) || _('Unable to load Tailscale peer status'))
		};
	}
}

return view.extend({
	load: loadPeerState,

	render: function(data) {
		var state = {
			peers: (data && data.peers) || [],
			error: (data && data.error) || '',
			probeResults: Object.create(null),
			probing: Object.create(null)
		};
		var filterMode = 'all';
		var tbody = E('tbody');
		var statusBox = E('div');
		var filterSelect = E('select', {
			id: 'filterMode',
			change: function(ev) {
				filterMode = ev.target.value;
				renderRows();
			}
		}, [
			E('option', { value: 'all' }, _('All')),
			E('option', { value: 'online' }, _('Online')),
			E('option', { value: 'subnets' }, _('Advertising subnets'))
		]);

		function filterPeers(peers) {
			if (filterMode === 'online')
				return peers.filter(function(peer) { return peer.online; });

			if (filterMode === 'subnets')
				return peers.filter(function(peer) { return peer.hasSubnetRoutes; });

			return peers;
		}

		function renderRows() {
			var filtered = filterPeers(state.peers);
			var rows;

			if (state.error) {
				dom.content(statusBox, E('div', {
					style: 'margin-bottom:10px;padding:8px 10px;border-left:3px solid #d97706;background:#fff7ed;color:#9a3412'
				}, state.error));
			} else {
				dom.content(statusBox, '');
			}

			if (!filtered.length) {
				rows = [
					E('tr', { class: 'tr' },
						E('td', {
							class: 'td left',
							colspan: '7'
						}, _('No peers match the selected filter.'))
					)
				];
			} else {
				rows = filtered.map(function(peer) {
					var result = state.probeResults[peer.id];
					var probing = !!state.probing[peer.id];
					var button = E('button', {
						class: 'btn cbi-button cbi-button-action',
						disabled: probing,
						click: L.bind(probePeer, null, peer)
					}, probing ? _('Probing...') : _('Probe'));
					var resultNode = probing
						? E('span', { style: 'color:#64748b' }, _('Probing...'))
						: renderProbeResult(result);

					return E('tr', { class: 'tr' }, [
						E('td', { class: 'td left' }, peer.name),
						E('td', { class: 'td left' }, peer.ip || '-'),
						E('td', { class: 'td left' }, renderStatusLabel(peer.online)),
						E('td', { class: 'td left' }, peer.lastSeen || '-'),
						E('td', { class: 'td left' }, renderRoleBadges(peer)),
						E('td', { class: 'td left' }, peer.routes.length ? peer.routes.join(', ') : '-'),
						E('td', { class: 'td left' }, E('div', {
							style: 'display:flex;align-items:center;gap:8px;flex-wrap:wrap'
						}, [
							button,
							resultNode
						]))
					]);
				});
			}

			dom.content(tbody, rows);
		}

		async function refreshPeers() {
			var next = await loadPeerState();
			if (next.ok) {
				state.peers = next.peers;
				state.error = '';
			} else {
				state.peers = [];
				state.error = next.error;
			}
			renderRows();
		}

		async function probePeer(peer) {
			var target = peer.probeTarget;

			if (!target) {
				state.probeResults[peer.id] = {
					ok: false,
					path: 'failed',
					summary: _('No probe target available'),
					raw: ''
				};
				renderRows();
				return;
			}

			state.probing[peer.id] = true;
			renderRows();

			try {
				var res = await fs.exec('/usr/sbin/tailscale_peer_probe', [target]);
				state.probeResults[peer.id] = parseProbeResult(
					res && res.stdout,
					res && (res.stderr || res.message || '')
				);
			} catch (e) {
				state.probeResults[peer.id] = parseProbeResult('', String((e && (e.message || e.stderr || e.stdout)) || _('Probe failed')));
			} finally {
				state.probing[peer.id] = false;
				renderRows();
			}
		}

		poll.add(async function() {
			await refreshPeers();
		});

		renderRows();

		return E('div', { class: 'cbi-map' }, [
			E('h2', { class: 'content' }, _('Tailscale Peers')),
			E('div', { class: 'cbi-map-descr' }, _('View all peers and manually probe whether traffic is direct or relayed through DERP.')),
			statusBox,
			E('div', {
				style: 'display:flex;align-items:center;gap:8px;margin-bottom:10px;flex-wrap:wrap'
			}, [
				E('label', { for: 'filterMode' }, _('Filter')),
				filterSelect
			]),
			E('table', {
				class: 'table',
				style: 'table-layout:fixed;width:100%'
			}, [
				E('thead', {}, E('tr', { class: 'tr table-titles' }, [
					E('th', { class: 'th left' }, _('Name')),
					E('th', { class: 'th left' }, _('Tailnet IP')),
					E('th', { class: 'th left' }, _('Status')),
					E('th', { class: 'th left' }, _('Last Seen')),
					E('th', { class: 'th left' }, _('Role')),
					E('th', { class: 'th left' }, _('Advertised Subnets')),
					E('th', { class: 'th left' }, _('Probe'))
				])),
				tbody
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
