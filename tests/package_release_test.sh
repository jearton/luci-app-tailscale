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
assert_contains "/usr/sbin/tailscale_adguard_dns_switch --preflight" root/usr/share/rpcd/acl.d/luci-app-tailscale.json
assert_contains "PROG=/usr/sbin/tailscale_adguard_dns_switch" root/etc/init.d/tailscale-adguard-dns

assert_not_exists root/lib/netifd/proto/tailscale.sh
assert_not_exists htdocs/luci-static/resources/protocol/tailscale.js

echo "package release tests passed"
