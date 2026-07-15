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

assert_peer_pagination_after_table() {
	file="$1"
	awk '
		/return E\('\''div'\'', \{ class: '\''cbi-map'\'' \}/ { in_return = 1 }
		in_return && /E\('\''table'\'', \{/ { table_line = NR }
		in_return && /^[[:space:]]*paginationBox[[:space:]]*$/ { pagination_line = NR }
		END {
			if (table_line && pagination_line && table_line < pagination_line)
				exit 0
			exit 1
		}
	' "$ROOT_DIR/$file" || fail "$file should render peer pagination below the peer table"
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
assert_contains "LUCI_DEPENDS:=+tailscale +jshn +curl +jq" Makefile
assert_contains '"$JQ_BIN" -nc' root/usr/sbin/tailscale_peer_probe
assert_contains "--argjson ok" root/usr/sbin/tailscale_peer_probe
assert_contains "ping --c=1 --timeout=2s" root/usr/sbin/tailscale_peer_probe
assert_not_contains "json_escape()" root/usr/sbin/tailscale_peer_probe
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
assert_contains 'msgid "Tailscale Peers"' po/templates/tailscale.pot
assert_contains 'msgid "Tailscale Peers"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "Tailscale 对端"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Tailscale Peers"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "Tailscale 對端"' po/zh_Hant/tailscale.po
assert_contains 'msgid "View all peers and manually probe whether traffic is direct or relayed through DERP."' po/templates/tailscale.pot
assert_contains 'msgid "View all peers and manually probe whether traffic is direct or relayed through DERP."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "查看所有对端，并手动探测流量是直连还是通过 DERP 中继。"' po/zh_Hans/tailscale.po
assert_contains 'msgid "View all peers and manually probe whether traffic is direct or relayed through DERP."' po/zh_Hant/tailscale.po
assert_contains 'msgstr "查看所有對端，並手動探測流量是直連還是透過 DERP 中繼。"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Unable to load Tailscale peer status"' po/templates/tailscale.pot
assert_contains 'msgid "Unable to load Tailscale peer status"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "无法加载 Tailscale 对端状态。"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Unable to load Tailscale peer status"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "無法載入 Tailscale 對端狀態。"' po/zh_Hant/tailscale.po
assert_contains 'msgid "No peers match the selected filter."' po/templates/tailscale.pot
assert_contains 'msgid "No peers match the selected filter."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "没有对端符合所选筛选条件。"' po/zh_Hans/tailscale.po
assert_contains 'msgid "No peers match the selected filter."' po/zh_Hant/tailscale.po
assert_contains 'msgstr "沒有對端符合所選篩選條件。"' po/zh_Hant/tailscale.po
assert_contains "No peers found" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains 'msgid "No peers found"' po/templates/tailscale.pot
assert_contains 'msgid "No peers found"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "没有找到对端"' po/zh_Hans/tailscale.po
assert_contains 'msgid "No peers found"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "沒有找到對端"' po/zh_Hant/tailscale.po
assert_contains 'msgid "No probe target available"' po/templates/tailscale.pot
assert_contains 'msgid "No probe target available"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "没有可用探测目标。"' po/zh_Hans/tailscale.po
assert_contains 'msgid "No probe target available"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "沒有可用探測目標。"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Probe failed"' po/templates/tailscale.pot
assert_contains 'msgid "Probe failed"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "探测失败"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Probe failed"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "探測失敗"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Not probed"' po/templates/tailscale.pot
assert_contains 'msgid "Not probed"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "未探测"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Not probed"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "未探測"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Probing..."' po/templates/tailscale.pot
assert_contains 'msgid "Probing..."' po/zh_Hans/tailscale.po
assert_contains 'msgstr "探测中..."' po/zh_Hans/tailscale.po
assert_contains 'msgid "Probing..."' po/zh_Hant/tailscale.po
assert_contains 'msgstr "探測中..."' po/zh_Hant/tailscale.po
assert_contains 'msgid "Probe"' po/templates/tailscale.pot
assert_contains 'msgid "Probe"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "探测"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Probe"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "探測"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Direct"' po/templates/tailscale.pot
assert_contains 'msgid "Direct"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "直连"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Direct"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "直連"' po/zh_Hant/tailscale.po
assert_contains 'msgid "DERP"' po/templates/tailscale.pot
assert_contains 'msgid "DERP"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "DERP 中继"' po/zh_Hans/tailscale.po
assert_contains 'msgid "DERP"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "DERP 中繼"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Failed"' po/templates/tailscale.pot
assert_contains 'msgid "Failed"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "失败"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Failed"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "失敗"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Unknown"' po/templates/tailscale.pot
assert_contains 'msgid "Unknown"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "未知"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Unknown"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "未知"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Filter"' po/templates/tailscale.pot
assert_contains 'msgid "Filter"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "筛选"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Filter"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "篩選"' po/zh_Hant/tailscale.po
assert_contains 'msgid "All"' po/templates/tailscale.pot
assert_contains 'msgid "All"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "全部"' po/zh_Hans/tailscale.po
assert_contains 'msgid "All"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "全部"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Online"' po/templates/tailscale.pot
assert_contains 'msgid "Online"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "在线"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Online"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "在線"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Offline"' po/templates/tailscale.pot
assert_contains 'msgid "Offline"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "离线"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Offline"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "離線"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Name"' po/templates/tailscale.pot
assert_contains 'msgid "Name"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "名称"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Name"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "名稱"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Tailnet IP"' po/templates/tailscale.pot
assert_contains 'msgid "Tailnet IP"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "Tailnet IP"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Tailnet IP"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "Tailnet IP"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Last Seen"' po/templates/tailscale.pot
assert_contains 'msgid "Last Seen"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "最后在线"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Last Seen"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "最後在線"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Role"' po/templates/tailscale.pot
assert_contains 'msgid "Role"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "角色"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Role"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "角色"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Exit node"' po/templates/tailscale.pot
assert_contains 'msgid "Exit node"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "出口节点"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Exit node"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "出口節點"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Advertising subnets"' po/templates/tailscale.pot
assert_contains 'msgid "Advertising subnets"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "发布网段"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Advertising subnets"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "發布網段"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Advertised Subnets"' po/templates/tailscale.pot
assert_contains 'msgid "Advertised Subnets"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "已发布网段"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Advertised Subnets"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "已發布網段"' po/zh_Hant/tailscale.po

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
assert_file htdocs/luci-static/resources/view/tailscale/peers.js
assert_file tests/peers_pagination_test.js
assert_contains "Tailscale Peers" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "filterMode" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "buildPeerGroups" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "paginatePeerGroups" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "PEER_PAGE_SIZE_DEFAULT = 25" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "PEER_PAGE_SIZE_OPTIONS" htdocs/luci-static/resources/view/tailscale/peers.js
assert_peer_pagination_after_table htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "peer-pagination-summary" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "peer-pagination-controls" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "justify-content:flex-end" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "margin-left:auto" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "split oversized groups into dedicated pages" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "pageSize === 0" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "pageIndex = 0" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "peer.userKey" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "peer-group-header" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "peer-group-title" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "border-left:4px solid #64748b" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "font-size:16px" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "peer.online ? '' : 'opacity:0.62'" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "Offline peers cannot be probed" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "type: 'button'" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "disabled: probing || !peer.online ? 'disabled' : null" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "preventDefault" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "stopPropagation" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "window.scrollTo" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "querySelector('.main-right')" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "restoreScrollState" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "scrollElement.scrollTop" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "renderRows(true)" htdocs/luci-static/resources/view/tailscale/peers.js
assert_not_contains "disabled: probing," htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "PROBE_MAX_ATTEMPTS = 5" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "PROBE_RETRY_DELAY_MS" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "Continuing probe %d/%d" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "%d probes; direct connection not established" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains 'msgid "Continuing probe %d/%d"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "继续探测 %d/%d"' po/zh_Hans/tailscale.po
assert_contains 'msgid "%d probes; direct connection not established"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "%d 次探测后仍未建立直连"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Continuing probe %d/%d"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "繼續探測 %d/%d"' po/zh_Hant/tailscale.po
assert_contains 'msgid "%d probes; direct connection not established"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "%d 次探測後仍未建立直連"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Items per page"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "每页数量"' po/zh_Hans/tailscale.po
assert_contains 'msgid "All peers"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "全部对端"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Showing %d-%d of %d peers"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "显示第 %d-%d 台，共 %d 台"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Page %d / %d"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "第 %d / %d 页"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Previous"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "上一页"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Next"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "下一页"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Offline peers cannot be probed"' po/templates/tailscale.pot
assert_contains 'msgid "Offline peers cannot be probed"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "离线设备不可探测"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Offline peers cannot be probed"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "離線設備不可探測"' po/zh_Hant/tailscale.po
assert_contains 'msgid "Unknown user"' po/templates/tailscale.pot
assert_contains 'msgid "Unknown user"' po/zh_Hans/tailscale.po
assert_contains 'msgstr "未知用户"' po/zh_Hans/tailscale.po
assert_contains 'msgid "Unknown user"' po/zh_Hant/tailscale.po
assert_contains 'msgstr "未知使用者"' po/zh_Hant/tailscale.po
assert_contains "Advertising subnets" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "tailscale_peer_probe" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "Probe" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "DERP" htdocs/luci-static/resources/view/tailscale/peers.js
assert_contains "Direct" htdocs/luci-static/resources/view/tailscale/peers.js
assert_not_contains "Probe all" htdocs/luci-static/resources/view/tailscale/peers.js
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
