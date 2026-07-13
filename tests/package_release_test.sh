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
assert_file root/usr/sbin/tailscale_helper
assert_file root/usr/sbin/tailscale_keepalive
assert_file root/usr/sbin/tailscale_adguard_dns_switch
assert_file root/usr/sbin/tailscale_peer_probe
assert_file root/usr/share/rpcd/acl.d/luci-app-tailscale.json
assert_contains "Peer probe" root/usr/sbin/tailscale_peer_probe
assert_file root/etc/uci-defaults/40_luci-tailscale
assert_contains '"admin/vpn/tailscale/peers"' root/usr/share/luci/menu.d/luci-app-tailscale.json
assert_contains '"title": "Peers"' root/usr/share/luci/menu.d/luci-app-tailscale.json
assert_contains '"path": "tailscale/peers"' root/usr/share/luci/menu.d/luci-app-tailscale.json
assert_before '"admin/vpn/tailscale/interface"' '"admin/vpn/tailscale/peers"' root/usr/share/luci/menu.d/luci-app-tailscale.json
assert_before '"admin/vpn/tailscale/peers"' '"admin/vpn/tailscale/log"' root/usr/share/luci/menu.d/luci-app-tailscale.json
assert_contains 'msgid "Peers"' po/templates/tailscale.pot
assert_contains 'msgid "Peers"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "对端列表"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Peers"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "對端列表"' po/zh_Hant/tailscale.po

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
assert_contains "form.Value.extend" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "KeepalivePeersValue, 'keepalive_peers'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "keepalive-peer-list" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "Only peers advertising subnet routes are shown" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "keepalive-peer-row" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "max-width:680px;width:100%" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "grid-template-columns:minmax(320px,1fr) minmax(140px,260px)" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "min-height:42px" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "keepalive-peer-main" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "keepalive-peer-check" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "display:flex;align-items:center;gap:10px;min-width:0" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "display:flex;align-items:center;justify-content:center;line-height:0;flex:0 0 24px" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "max-width:260px" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "max-width:820px" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "grid-template-columns:24px minmax(160px,1fr) auto" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "grid-template-columns:24px minmax(180px,1fr) minmax(140px,260px)" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "padding:10px 12px" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "grid-template-columns:24px 1fr" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "form.AbstractValue, 'keepalive_peers'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "form.MultiValue, 'keepalive_peers'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains 'msgid "Keepalive"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "保活"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Peer Keepalive"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "启用"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Peer Keepalive"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "啟用"' po/zh_Hant/tailscale.po
assert_not_contains 'msgstr "对端保活"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Subnets"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "子网"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Only peers advertising subnet routes are shown. Selected peers are periodically pinged to keep cross-subnet paths active."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "仅显示对端也发布了网段的设备；选中的设备会被定时 Tailscale ping，用于保持跨网段路径活跃。"' po/zh_Hans/tailscale.po
assert_not_contains "子网路由" po/zh_Hans/tailscale.po
assert_not_contains "子網路由" po/zh_Hant/tailscale.po
assert_contains 'msgid "AdGuard DNS"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "AdGuard DNS"' po/zh_Hans/tailscale.po
assert_contains 'msgid "AdGuard Username"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "AdGuard 用户名"' po/zh_Hans/tailscale.po
assert_contains "Expected Internal IPs" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains 'msgid "Expected Internal IPs"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "预期内网 IP"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "啟用 AdGuard DNS 自動切換前至少需要填寫一個預期內網 IP。"' po/zh_Hant/tailscale.po
assert_not_contains "Expected Health IPs" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "预期健康 IP" po/zh_Hans/tailscale.po
assert_not_contains "預期健康 IP" po/zh_Hant/tailscale.po
assert_contains "100.100.100.100" root/usr/sbin/tailscale_adguard_dns_switch
assert_contains "100.100.100.100" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "'subnet_routes'" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "Subnet Routes" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "No Available Subnet Routes" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "config_get subnet_routes" root/etc/init.d/tailscale
assert_not_contains 'SUBNET_ROUTES="$subnet_routes"' root/etc/init.d/tailscale
assert_not_contains "list subnet_routes" root/etc/config/tailscale
assert_not_contains 'msgid "Subnet Routes"' po/templates/tailscale.pot
assert_not_contains 'msgid "No Available Subnet Routes"' po/templates/tailscale.pot
assert_not_contains 'msgid "Subnet Routes"' po/zh_Hans/tailscale.po
assert_not_contains 'msgid "No Available Subnet Routes"' po/zh_Hans/tailscale.po
assert_not_contains 'msgid "Subnet Routes"' po/zh_Hant/tailscale.po
assert_not_contains 'msgid "No Available Subnet Routes"' po/zh_Hant/tailscale.po
assert_not_contains "Tailscale Accept DNS" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "Accept DNS must be enabled before enabling AdGuard DNS auto switch." htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains 'msgid "Tailscale Accept DNS"' po/zh_Hans/tailscale.po
assert_not_contains 'msgid "Accept DNS must be enabled before enabling AdGuard DNS auto switch."' po/zh_Hans/tailscale.po
assert_contains "PROGA=/usr/sbin/tailscale_adguard_dns_switch" root/etc/init.d/tailscale
assert_contains 'tailscale_adguard_dns "$cfg"' root/etc/init.d/tailscale
assert_contains 'tailscale_adguard_dns_apply_down "$cfg"' root/etc/init.d/tailscale
assert_contains "--apply-profile down" root/etc/init.d/tailscale
assert_not_contains "adguard_health_dns" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "Health Check DNS Server" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "adguard_health_dns" root/etc/config/tailscale
assert_not_contains "adguard_clear_cache" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "Clear AdGuard Cache After Switch" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "adguard_clear_cache" root/etc/config/tailscale
assert_not_contains 'msgid "Health Check DNS Server"' po/zh_Hans/tailscale.po
assert_not_contains 'msgid "Clear AdGuard Cache After Switch"' po/zh_Hans/tailscale.po
assert_contains "placeholder = hasAdguardPassword ? _('Configured') : ''" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "placeholder = hasAuthKey ? _('Configured') : ''" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "Leave blank to keep the existing AdGuard password; enter a new value to replace it." htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains "Leave blank to keep the existing auth key; enter a new value to replace it." htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "placeholder = hasAdguardPassword ? _('Configured; leave blank to keep existing value.') : ''" htdocs/luci-static/resources/view/tailscale/setting.js
assert_not_contains "placeholder = hasAuthKey ? _('Configured; leave blank to keep existing value.') : ''" htdocs/luci-static/resources/view/tailscale/setting.js
assert_contains 'msgid "Configured"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "已配置"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Leave blank to keep the existing AdGuard password; enter a new value to replace it."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "留空则保留现有 AdGuard 密码；填写新值则覆盖。"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Leave blank to keep the existing auth key; enter a new value to replace it."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "留空则保留现有认证密钥；填写新值则覆盖。"' po/zh_Hans/tailscale.po
assert_contains "/usr/sbin/tailscale_adguard_dns_switch --preflight" root/usr/share/rpcd/acl.d/luci-app-tailscale.json
assert_contains '"/usr/sbin/tailscale_peer_probe": [ "exec" ]' root/usr/share/rpcd/acl.d/luci-app-tailscale.json

assert_not_exists root/lib/netifd/proto/tailscale.sh
assert_not_exists htdocs/luci-static/resources/protocol/tailscale.js
assert_not_exists root/etc/init.d/tailscale-adguard-dns

echo "package release tests passed"
