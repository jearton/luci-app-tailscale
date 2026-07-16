const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('htdocs/luci-static/resources/view/tailscale/setting.js', 'utf8');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

const loadMatch = source.match(/load\(\)\s*\{([\s\S]*?)\n\t\},\n\n\trender/);
assert(loadMatch, 'expected setting view to define a load() method');

assert(
	!loadMatch[1].includes('tailscale_adguard_dns_switch'),
	'setting load() must not block first render on AdGuard DNS preflight'
);

assert(
	source.includes('refreshAdguardPreflightStatus'),
	'setting view should refresh AdGuard DNS preflight status after initial render'
);

assert(source.includes("method: 'secret_status'"), 'setting view must load credential presence through a dedicated RPC');
assert(source.includes("method: 'set_secret'"), 'setting view must write credentials through a dedicated RPC');
assert(!source.includes("uci.get('tailscale', 'settings', 'adguard_password')"), 'browser must never read the persisted AdGuard password');
assert(!source.includes("uci.get('tailscale', 'settings', 'authkey')"), 'browser must never read the persisted auth key');
assert(!source.includes("uci.set('tailscale', section_id, 'adguard_password'"), 'browser must not persist AdGuard passwords in readable UCI');
assert(!source.includes("uci.set('tailscale', section_id, 'authkey'"), 'browser must not persist auth keys in readable UCI');

const helperSource = source.split('return view.extend({')[0];

const candidateValues = {
	apiUrl: 'http://127.0.0.1:3001',
	username: 'candidate-user',
	password: 'candidate-password',
	keepPassword: false,
	defaultUpstreams: ['1.1.1.1', '8.8.8.8'],
	tailnetUpstreams: ['[/example.test/]100.100.100.100'],
	healthDomain: 'health.example.test',
	expectedIps: ['10.23.0.15', '10.23.0.16']
};

async function testEnablementWrite({ persistedEnabled, value, preflightResult, preflightError, candidateRequest }) {
	const calls = [];
	const context = {
		module: { exports: {} },
		console,
		_: value => value,
		rpc: {
			declare: spec => {
				if (spec.object !== 'luci.tailscale')
					return function() {};
				return async (...args) => {
					calls.push({ type: 'rpc', object: spec.object, method: spec.method, args });
					if (preflightError)
						throw preflightError;
					return preflightResult || {};
				};
			}
		},
		fs: {},
		uci: {
			get: (config, section, option) => {
				calls.push({ type: 'get', config, section, option });
				return persistedEnabled ? '1' : '0';
			},
			set: (config, section, option, nextValue) => {
				calls.push({ type: 'set', config, section, option, value: nextValue });
				return 'set-result';
		}
	}
	};

	vm.runInNewContext(
		`${helperSource}\nmodule.exports = { buildAdguardPreflightRequest, writeAdguardDnsSwitchEnabled };`,
		context
	);

	const builtCandidateRequest = context.module.exports.buildAdguardPreflightRequest(candidateValues);

	let result;
	let error;
	try {
		result = await context.module.exports.writeAdguardDnsSwitchEnabled(
			'settings',
			value,
			candidateRequest || builtCandidateRequest
		);
	} catch (e) {
		error = e;
	}

	return { calls, result, error };
}

(async () => {
	let outcome = await testEnablementWrite({
		persistedEnabled: false,
		value: '1',
		preflightResult: { adguard_process: 'pass', health_check: 'fail', ready: 'fail' }
	});
	assert(outcome.calls.filter(call => call.type === 'rpc').length === 1, '0 -> 1 must run one fresh preflight RPC');
	const preflightCall = outcome.calls.find(call => call.type === 'rpc');
	assert(preflightCall.object === 'luci.tailscale' && preflightCall.method === 'adguard_preflight', 'preflight must use the dedicated Tailscale RPC method');
	assert(preflightCall.args[0] === '1', 'preflight RPC must opt into candidate configuration');
	assert(preflightCall.args[1] === candidateValues.apiUrl, 'preflight RPC must receive the candidate API URL');
	assert(preflightCall.args[4] === candidateValues.password, 'preflight RPC must receive a newly entered candidate password');
	assert(preflightCall.args[5] === '1.1.1.1\n8.8.8.8', 'preflight RPC must preserve candidate upstream list boundaries');
	assert(preflightCall.args[8] === '10.23.0.15\n10.23.0.16', 'preflight RPC must receive candidate expected IPs');
	assert(outcome.calls.every(call => call.type !== 'set'), 'failed initial enablement must not write the flag');
	assert(outcome.error && /status checks/i.test(outcome.error.message), 'failed initial enablement must reject save with a useful error');

	outcome = await testEnablementWrite({
		persistedEnabled: false,
		value: '1',
		preflightResult: { adguard_process: 'pass', health_check: 'pass', ready: 'pass' }
	});
	assert(outcome.calls.filter(call => call.type === 'rpc').length === 1, 'passing 0 -> 1 must still use a fresh preflight');
	assert(outcome.calls.some(call => call.type === 'set' && call.value === '1'), 'passing initial enablement must write the flag');
	assert(outcome.result === 'set-result', 'write hook must preserve the Promise-capable UCI write result');

	outcome = await testEnablementWrite({
		persistedEnabled: true,
		value: '1',
		preflightError: new Error('transient health failure')
	});
	assert(outcome.calls.every(call => call.type !== 'rpc'), 'already-enabled saves must not rerun or gate on preflight');
	assert(outcome.calls.some(call => call.type === 'set' && call.value === '1'), 'already-enabled saves must remain writable');

	outcome = await testEnablementWrite({
		persistedEnabled: false,
		value: '0',
		preflightError: new Error('AdGuard unavailable')
	});
	assert(outcome.calls.every(call => call.type !== 'rpc'), 'disabled saves must not run preflight');
	assert(outcome.calls.some(call => call.type === 'set' && call.value === '0'), 'disabled saves must remain writable');

	const keepPasswordRequest = vm.runInNewContext(
		`${helperSource}\nbuildAdguardPreflightRequest(${JSON.stringify({ ...candidateValues, password: '', keepPassword: true })})`,
		{
			module: { exports: {} },
			console,
			_: value => value,
			rpc: { declare: () => function() {} },
			fs: {},
			uci: {}
		}
	);
	assert(keepPasswordRequest.password_set === '0', 'blank password must tell preflight to retain the persisted secret');
	assert(keepPasswordRequest.password === '', 'persisted password must not be copied into the browser RPC request');

	assert(
		source.includes('buildAdguardPreflightRequest({') && source.includes('writeAdguardDnsSwitchEnabled(section_id, value, candidateRequest)'),
		'the AdGuard flag write hook must build candidate values from the live form before preflight'
	);

	console.log('setting preflight tests passed');
})().catch(error => {
	console.error(error);
	process.exit(1);
});
