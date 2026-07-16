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

const helperSource = source.split('return view.extend({')[0];

async function testEnablementWrite({ persistedEnabled, value, preflightStdout, preflightError }) {
	const calls = [];
	const context = {
		module: { exports: {} },
		console,
		_: value => value,
		rpc: { declare: () => function() {} },
		fs: {
			exec: async (path, args) => {
				calls.push({ type: 'exec', path, args });
				if (preflightError)
					throw preflightError;
				return { stdout: preflightStdout || '' };
			}
		},
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
		`${helperSource}\nmodule.exports = { writeAdguardDnsSwitchEnabled };`,
		context
	);

	let result;
	let error;
	try {
		result = await context.module.exports.writeAdguardDnsSwitchEnabled('settings', value);
	} catch (e) {
		error = e;
	}

	return { calls, result, error };
}

(async () => {
	let outcome = await testEnablementWrite({
		persistedEnabled: false,
		value: '1',
		preflightStdout: 'adguard_process=pass\nhealth_check=fail\nready=fail\n'
	});
	assert(outcome.calls.filter(call => call.type === 'exec').length === 1, '0 -> 1 must run one fresh preflight');
	assert(outcome.calls.every(call => call.type !== 'set'), 'failed initial enablement must not write the flag');
	assert(outcome.error && /status checks/i.test(outcome.error.message), 'failed initial enablement must reject save with a useful error');

	outcome = await testEnablementWrite({
		persistedEnabled: false,
		value: '1',
		preflightStdout: 'adguard_process=pass\nhealth_check=pass\nready=pass\n'
	});
	assert(outcome.calls.filter(call => call.type === 'exec').length === 1, 'passing 0 -> 1 must still use a fresh preflight');
	assert(outcome.calls.some(call => call.type === 'set' && call.value === '1'), 'passing initial enablement must write the flag');
	assert(outcome.result === 'set-result', 'write hook must preserve the Promise-capable UCI write result');

	outcome = await testEnablementWrite({
		persistedEnabled: true,
		value: '1',
		preflightError: new Error('transient health failure')
	});
	assert(outcome.calls.every(call => call.type !== 'exec'), 'already-enabled saves must not rerun or gate on preflight');
	assert(outcome.calls.some(call => call.type === 'set' && call.value === '1'), 'already-enabled saves must remain writable');

	outcome = await testEnablementWrite({
		persistedEnabled: false,
		value: '0',
		preflightError: new Error('AdGuard unavailable')
	});
	assert(outcome.calls.every(call => call.type !== 'exec'), 'disabled saves must not run preflight');
	assert(outcome.calls.some(call => call.type === 'set' && call.value === '0'), 'disabled saves must remain writable');

	console.log('setting preflight tests passed');
})().catch(error => {
	console.error(error);
	process.exit(1);
});
