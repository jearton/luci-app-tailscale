const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('htdocs/luci-static/resources/view/tailscale/peers.js', 'utf8');
const helperSource = source.split('return view.extend({')[0];
const context = {
	module: { exports: {} },
	console,
	_: value => value
};

vm.runInNewContext(`${helperSource}\nmodule.exports = { parseStatus, buildPeerGroups, paginatePeerGroups, parseProbeResult, appendProbeSummary };`, context);

const { parseStatus, buildPeerGroups, paginatePeerGroups, parseProbeResult, appendProbeSummary } = context.module.exports;

function peer(id) {
	return { id: String(id) };
}

function group(name, count) {
	return {
		key: name,
		name,
		loginName: '',
		peers: Array.from({ length: count }, (_, index) => peer(`${name}-${index}`))
	};
}

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function groupNames(page) {
	return page.groups.map(item => item.name).join(',');
}

const mixedGroups = [group('user-a', 20), group('user-b', 5), group('user-c', 10)];
let page = paginatePeerGroups(mixedGroups, 25, 0);
assert(page.pageCount === 2, `expected two pages, got ${page.pageCount}`);
assert(groupNames(page) === 'user-a,user-b', `unexpected first page groups: ${groupNames(page)}`);
assert(page.start === 1 && page.end === 25 && page.total === 35, 'unexpected first page range');

page = paginatePeerGroups(mixedGroups, 25, 1);
assert(groupNames(page) === 'user-c', `unexpected second page groups: ${groupNames(page)}`);
assert(page.start === 26 && page.end === 35, 'unexpected second page range');

const oversizedGroups = [group('large-user', 40), group('small-user', 5)];
page = paginatePeerGroups(oversizedGroups, 25, 0);
assert(groupNames(page) === 'large-user', `unexpected oversized first page groups: ${groupNames(page)}`);
assert(page.groups[0].peers.length === 25, `expected first chunk of 25, got ${page.groups[0].peers.length}`);

page = paginatePeerGroups(oversizedGroups, 25, 1);
assert(groupNames(page) === 'large-user', `unexpected oversized second page groups: ${groupNames(page)}`);
assert(page.groups[0].peers.length === 15, `expected second chunk of 15, got ${page.groups[0].peers.length}`);

page = paginatePeerGroups(oversizedGroups, 25, 2);
assert(groupNames(page) === 'small-user', `unexpected oversized third page groups: ${groupNames(page)}`);
assert(page.groups[0].peers.length === 5, `expected small group page of 5, got ${page.groups[0].peers.length}`);

page = paginatePeerGroups(oversizedGroups, 0, 0);
assert(page.pageCount === 1, `expected all mode single page, got ${page.pageCount}`);
assert(groupNames(page) === 'large-user,small-user', `unexpected all mode groups: ${groupNames(page)}`);

const normalizedPeers = parseStatus(JSON.stringify({
	User: {
		'1': { DisplayName: 'Zeta User', LoginName: 'zeta@example.test' },
		'2': { DisplayName: 'Alpha User', LoginName: 'alpha@example.test' }
	},
	Peer: {
		'node:gateway': {
			HostName: 'gateway',
			DNSName: 'gateway.example.ts.net.',
			TailscaleIPs: ['100.64.0.20'],
			PrimaryRoutes: ['10.20.0.0/24', '', null],
			UserID: 2,
			Online: 1
		},
		'node:alpha': {
			HostName: 'legacy-host',
			DNSName: 'alpha.example.ts.net.',
			TailscaleIPs: ['100.64.0.10'],
			PrimaryRoutes: [],
			UserID: '1',
			Online: false
		},
		'node:unknown': {
			HostName: '',
			DNSName: '',
			TailscaleIPs: ['100.64.0.30'],
			PrimaryRoutes: null,
			Online: true
		}
	}
}));

assert(normalizedPeers.map(item => item.id).join(',') === 'node:unknown,node:alpha,node:gateway', 'status peers should normalize names and sort deterministically');
assert(normalizedPeers[1].name === 'alpha (legacy-host)', 'status normalization should combine distinct short DNS and host names');
assert(normalizedPeers[2].probeTarget === '100.64.0.20', 'status normalization should prefer the Tailscale IP as probe target');
assert(normalizedPeers[2].routes.join(',') === '10.20.0.0/24' && normalizedPeers[2].hasSubnetRoutes, 'status normalization should remove empty routes and flag advertised subnets');
assert(normalizedPeers[0].userKey === 'unknown', 'missing user IDs should normalize into the unknown group');

const normalizedGroups = buildPeerGroups(normalizedPeers);
assert(normalizedGroups.map(item => item.name).join(',') === 'Alpha User,Unknown user,Zeta User', 'peer groups should sort by normalized user display name');
assert(normalizedGroups[0].peers[0].id === 'node:gateway', 'peer grouping should retain the normalized user association');

const largeUserId = '9007199254740993';
const largeIdPeers = parseStatus(`{"User":{"${largeUserId}":{"DisplayName":"Large ID User"}},"Peer":{"node:large":{"HostName":"large-id-peer","TailscaleIPs":["100.64.0.99"],"UserID":${largeUserId},"Online":true}}}`);
assert(largeIdPeers[0].userKey === largeUserId, 'status parsing must preserve UserID values larger than JavaScript safe integers');
assert(largeIdPeers[0].userName === 'Large ID User', 'large UserID values must still resolve the correct user metadata');

const derpProbe = parseProbeResult('{"ok":true,"path":"derp","relay":"test-relay","summary":"DERP test-relay 24 ms"}', 'ignored');
assert(derpProbe.path === 'derp' && derpProbe.relay === 'test-relay', 'probe parser should preserve a valid DERP result');
const progressiveProbe = appendProbeSummary(derpProbe, 'Continuing probe 1/5');
assert(progressiveProbe.summary === 'DERP test-relay 24 ms - Continuing probe 1/5', 'progressive DERP parsing should append the retry status');
assert(derpProbe.summary === 'DERP test-relay 24 ms', 'progressive probe summary should not mutate the parsed result');
const failedProbe = parseProbeResult('{invalid', 'probe output was incomplete');
assert(failedProbe.path === 'failed' && failedProbe.summary === 'probe output was incomplete', 'invalid progressive probe output should use the supplied failure detail');

function createElement(tag, attrs, children) {
	if (arguments.length === 2 && (typeof attrs !== 'object' || Array.isArray(attrs))) {
		children = attrs;
		attrs = {};
	}

	return {
		tag,
		attrs: attrs || {},
		children: children == null ? [] : (Array.isArray(children) ? children : [children])
	};
}

async function testRefreshFailureClearsStaleRows() {
	let pollCallback;
	const viewContext = {
		console,
		_: value => value,
		E: createElement,
		dom: {
			content: (node, content) => {
				node.content = content;
			}
		},
		fs: {
			exec: async () => ({ code: 1, stderr: 'status refresh unavailable' })
		},
		poll: {
			add: callback => {
				pollCallback = callback;
			}
		},
		view: {
			extend: value => value
		}
	};
	const viewObject = vm.runInNewContext(`
		String.prototype.format = function() {
			var args = arguments;
			var index = 0;
			return String(this).replace(/%[sd]/g, function() { return String(args[index++]); });
		};
		(function() { ${source}\n })();
	`, viewContext);
	const stalePeer = {
		id: 'stale-peer-id',
		name: 'stale-peer-name',
		ip: '100.64.0.40',
		userKey: '1',
		userName: 'Example User',
		userLoginName: 'user@example.test',
		online: true,
		lastSeen: '-',
		exitNode: false,
		routes: [],
		hasSubnetRoutes: false,
		probeTarget: '100.64.0.40'
	};
	const rendered = viewObject.render({ ok: true, peers: [stalePeer], error: '' });
	assert(JSON.stringify(rendered).includes('stale-peer-name'), 'refresh test should begin with a rendered stale peer');
	assert(typeof pollCallback === 'function', 'peer view should register its refresh callback');

	await pollCallback();
	const refreshed = JSON.stringify(rendered);
	assert(!refreshed.includes('stale-peer-name'), 'failed refresh must clear stale peer rows');
	assert(refreshed.includes('status refresh unavailable'), 'failed refresh should render the current status error');
	assert(refreshed.includes('No peers found'), 'failed refresh should render the empty peer state');
}

testRefreshFailureClearsStaleRows().then(() => {
	console.log('peers pagination and behavior tests passed');
}).catch(error => {
	console.error(error);
	process.exit(1);
});
