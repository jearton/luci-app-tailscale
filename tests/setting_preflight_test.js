const fs = require('fs');

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

console.log('setting preflight tests passed');
