const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('htdocs/luci-static/resources/view/tailscale/setting.js', 'utf8');

function assert(value, message) {
	if (!value)
		throw new Error(message);
}

assert(source.includes("uci.load('tailscale_openclash')"), 'setting view must load the isolated OpenClash UCI package');
assert(source.includes("method: 'openclash_bypass_status'"), 'setting view must use the read-only status RPC');
assert(source.includes("uci.set('tailscale_openclash', 'settings', 'enabled'"), 'toggle must write only the isolated UCI package');
assert(!source.includes("uci.set('tailscale', section_id, 'openclash"), 'toggle must not write the core Tailscale UCI package');

const loadMatch = source.match(/load\(\)\s*\{([\s\S]*?)\n\t\},\n\n\trender/);
assert(loadMatch, 'expected setting view to define a load() method');
assert(!loadMatch[1].includes('callOpenclashBypassStatus('), 'OpenClash status must not block initial page rendering');
assert(source.includes('refreshOpenclashBypassStatus'), 'status must refresh after render');

function createRuntime() {
	const rpcDeclarations = [];
	const rpcCalls = [];
	const uciLoads = [];
	const uciSets = [];
	const scheduled = [];
	const maps = [];
	const statusNode = { textContent: '' };
	const openclashUci = { enabled: '1' };
	const luciString = value => String(value);
	luciString.format = (format, ...values) => format.replace(/%s/g, () => values.shift());

	function Option(option) {
		this.option = option;
	}

	Option.prototype.depends = function() {};
	Option.prototype.value = function() {};
	Option.prototype.formvalue = function() { return ''; };
	Option.prototype.cbid = function(section_id) { return section_id + '.' + this.option; };

	function Section() {
		this.tabs = [];
		this.options = [];
	}

	Section.prototype.tab = function(tab) {
		this.tabs.push(tab);
	};

	Section.prototype.taboption = function(tab, Type, option) {
		const value = new Type(option);
		value.tab = tab;
		this.options.push(value);
		return value;
	};

	Section.prototype.option = function(Type, option) {
		const value = new Type(option);
		this.options.push(value);
		return value;
	};

	function Map(config) {
		this.config = config;
		this.sections = [];
		this.data = {
			save: async () => {},
			load: async () => {}
		};
		maps.push(this);
	}

	Map.prototype.section = function() {
		const section = new Section();
		this.sections.push(section);
		return section;
	};

	Map.prototype.render = function() {
		return Promise.resolve({ map: this });
	};

	const form = {
		Map,
		TypedSection: Option,
		NamedSection: Option,
		Flag: Option,
		DummyValue: Option,
		Value: Option,
		ListValue: Option,
		DynamicList: Option,
		MultiValue: Option
	};
	form.Value.extend = properties => {
		function ExtendedOption(option) {
			Option.call(this, option);
		}
		ExtendedOption.prototype = Object.assign(Object.create(Option.prototype), properties);
		return ExtendedOption;
	};

	const context = {
		module: { exports: {} },
		console,
		Promise,
		Object,
		String: luciString,
		Array,
		Set,
		Error,
		_: value => value,
		E: (tag, attrs, children) => ({ tag, attrs, children }),
		form,
		fs: {},
		network: { getNetworks: async () => [] },
		poll: { add: () => {} },
		rpc: {
			declare: spec => {
				rpcDeclarations.push(spec);
				return async (...args) => {
					rpcCalls.push({ method: spec.method, args });
					if (spec.method === 'secret_status')
						return { authkey_set: '0', adguard_password_set: '0' };
					if (spec.method === 'openclash_bypass_status')
						return { state: 'active' };
					return {};
				};
			}
		},
		uci: {
			load: async config => {
				uciLoads.push(config);
			},
			get: (config, section, option) => {
				if (config === 'tailscale_openclash' && section === 'settings' && option === 'enabled')
					return openclashUci.enabled;
				return '';
			},
			set: (config, section, option, value) => {
				uciSets.push({ config, section, option, value });
				if (config === 'tailscale_openclash' && section === 'settings' && option === 'enabled')
					openclashUci.enabled = value;
				return Promise.resolve('uci-set');
			},
			sections: () => []
		},
		ui: { showModal: () => {}, hideModal: () => {} },
		document: {
			getElementById: id => id === 'openclash_bypass_status' ? statusNode : null
		},
		window: {
			setTimeout: (callback, delay) => {
				scheduled.push({ callback, delay });
				return scheduled.length;
			}
		}
	};

	const viewObject = vm.runInNewContext(`(function() {\n${source}\n})()`, Object.assign(context, {
		view: { extend: value => value }
	}));

	return { viewObject, rpcDeclarations, rpcCalls, uciLoads, uciSets, scheduled, maps, statusNode };
}

(async () => {
	const runtime = createRuntime();
	const openclashStatusDeclaration = runtime.rpcDeclarations.find(spec => spec.method === 'openclash_bypass_status');
	assert(openclashStatusDeclaration, 'view must declare the OpenClash status RPC');
	assert(!openclashStatusDeclaration.params, 'OpenClash status RPC must not accept caller-controlled command arguments');

	const data = await runtime.viewObject.load();
	assert(runtime.uciLoads.includes('tailscale_openclash'), 'load() must read the isolated OpenClash UCI package');
	assert(!runtime.rpcCalls.some(call => call.method === 'openclash_bypass_status'), 'load() must not call OpenClash status RPC');

	await runtime.viewObject.render(data);
	assert(!runtime.rpcCalls.some(call => call.method === 'openclash_bypass_status'), 'render() must schedule, not await, OpenClash status RPC');
	const refresh = runtime.scheduled.find(entry => entry.callback.name === 'refreshOpenclashBypassStatus');
	assert(refresh && refresh.delay === 0, 'render() must queue the OpenClash status refresh immediately after rendering');
	await refresh.callback();
	assert(runtime.statusNode.textContent === 'Enabled and active', 'async status refresh must render the helper state label');

	const map = runtime.maps.find(candidate => candidate.config === 'tailscale');
	const openclashOption = map.sections
		.flatMap(section => section.options)
		.find(option => option.tab === 'openclash' && option.option === 'openclash_bypass_enabled');
	assert(openclashOption, 'render() must create the OpenClash bypass toggle in its own tab');
	assert(openclashOption.cfgvalue() === '1', 'toggle must read the isolated enabled value');
	assert(await openclashOption.write('settings', '0') === 'uci-set', 'toggle write must preserve the UCI result');
	assert(await openclashOption.remove('settings') === 'uci-set', 'toggle remove must preserve the UCI result');
	assert(
		runtime.uciSets.length === 2 && runtime.uciSets.every(call =>
			call.config === 'tailscale_openclash' &&
			call.section === 'settings' &&
			call.option === 'enabled'
		),
		'toggle save paths must only write tailscale_openclash.settings.enabled'
	);
	assert(runtime.uciSets[0].value === '0' && runtime.uciSets[1].value === '0', 'toggle disable and remove must persist disabled state');

	console.log('setting OpenClash bypass tests passed');
})().catch(error => {
	console.error(error);
	process.exit(1);
});
