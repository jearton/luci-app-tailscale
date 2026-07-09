#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_file() {
	[ -f "$ROOT_DIR/$1" ] || fail "missing required package file: $1"
}

assert_contains() {
	needle="$1"
	file="$2"
	grep -F -- "$needle" "$ROOT_DIR/$file" >/dev/null || fail "$file should contain: $needle"
}

assert_not_contains() {
	needle="$1"
	file="$2"
	if grep -F -- "$needle" "$ROOT_DIR/$file" >/dev/null; then
		fail "$file should not contain: $needle"
	fi
}

line_number() {
	needle="$1"
	file="$2"
	grep -nF -- "$needle" "$ROOT_DIR/$file" | head -n 1 | cut -d: -f1
}

assert_before() {
	first="$1"
	second="$2"
	file="$3"
	first_line="$(line_number "$first" "$file")"
	second_line="$(line_number "$second" "$file")"
	[ -n "$first_line" ] || fail "$file should contain: $first"
	[ -n "$second_line" ] || fail "$file should contain: $second"
	[ "$first_line" -lt "$second_line" ] || fail "$file should place '$first' before '$second'"
}

assert_not_exists() {
	[ ! -e "$ROOT_DIR/$1" ] || fail "$1 should not exist"
}

assert_contains "PKG_VERSION:=1.2.7" Makefile
assert_file .github/workflows/release.yml
assert_contains "tags:" .github/workflows/release.yml
assert_contains "v*" .github/workflows/release.yml
assert_contains "luci-app-tailscale_*.ipk" .github/workflows/release.yml
assert_contains "luci-app-tailscale-*.apk" .github/workflows/release.yml

assert_file htdocs/luci-static/resources/view/tailscale/setting.js
assert_file root/etc/config/tailscale
assert_file root/etc/init.d/tailscale
assert_file root/etc/init.d/tailscale-adguard-dns
assert_file root/usr/sbin/tailscale_helper
assert_file root/usr/sbin/tailscale_keepalive
assert_file root/usr/sbin/tailscale_adguard_dns_switch
assert_file root/usr/share/rpcd/acl.d/luci-app-tailscale.json
assert_file root/etc/uci-defaults/40_luci-tailscale

assert_contains "Peer Keepalive" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "AdGuard DNS" htdocs/luci-static/resources/view/tailscale/setting.js
assert_before "AdGuard API URL" "_adguard_dns_status" htdocs/luci-static/resources/view/tailscale/setting.js
assert_before "AdGuard Username" "_adguard_dns_status" htdocs/luci-static/resources/view/tailscale/setting.js
assert_before "AdGuard Password" "_adguard_dns_status" htdocs/luci-static/resources/view/tailscale/setting.js
assert_before "_adguard_dns_status" "Enable AdGuard DNS Auto Switch" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "adguardEnvironmentChecks" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "AdGuard DNS auto switch cannot be enabled until every environment status check passes." htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "keepalivePeerAliases" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "shortDnsName" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "hasSubnetRoutes" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "No subnet routes" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "s.tab('keepalive'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "form.AbstractValue, 'keepalive_peers'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "keepalive-peer-list" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "form.MultiValue, 'keepalive_peers'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains 'msgid "Keepalive"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "保活"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Subnets"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "子网"' po/zh_Hans/tailscale.po
assert_contains 'msgid "AdGuard DNS"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "AdGuard DNS"' po/zh_Hans/tailscale.po
assert_contains 'msgid "AdGuard Username"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "AdGuard 用户名"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Health Check DNS Server"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "健康检查 DNS 服务器"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Configured; leave blank to keep existing value."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "已配置；留空则保留现有值。"' po/zh_Hans/tailscale.po
assert_contains "/usr/sbin/tailscale_adguard_dns_switch --preflight" root/usr/share/rpcd/acl.d/luci-app-tailscale.json
assert_contains "PROG=/usr/sbin/tailscale_adguard_dns_switch" root/etc/init.d/tailscale-adguard-dns

assert_not_exists root/lib/netifd/proto/tailscale.sh
assert_not_exists htdocs/luci-static/resources/protocol/tailscale.js

echo "package release tests passed"
