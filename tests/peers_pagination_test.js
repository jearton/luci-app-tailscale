const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync('htdocs/luci-static/resources/view/tailscale/peers.js', 'utf8');
const helperSource = source.split('function parseProbeResult')[0];
const context = {
	module: { exports: {} },
	console
};

vm.runInNewContext(`${helperSource}\nmodule.exports = { paginatePeerGroups };`, context);

const { paginatePeerGroups } = context.module.exports;

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

console.log('peers pagination tests passed');
