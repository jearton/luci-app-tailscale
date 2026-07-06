# AdGuard DNS Auto Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional LuCI-managed AdGuard Home DNS auto-switcher that routes selected Tailnet domains to `100.100.100.100` only while Tailscale DNS is healthy, and falls back to public DNS when it is not.

**Architecture:** Keep Tailscale DNS behavior native: `accept_dns=1` still lets Tailscale manage `/etc/resolv.conf`. Add a separate procd service and script that watches Tailnet DNS health, then updates AdGuard Home `upstream_dns` via the HTTP API using either an up profile or a down profile. LuCI stores all configuration in `/etc/config/tailscale`, shows preflight status, hides AdGuard credentials, and blocks enabling when required checks fail.

**Tech Stack:** OpenWrt rc.common/procd, POSIX shell, UCI, BusyBox tools, curl, AdGuard Home HTTP API, LuCI form JS, shell tests with fake command shims.

---

## File Map

- Create `root/usr/sbin/tailscale_adguard_dns_switch`: runtime script for preflight, health checks, profile generation, AdGuard API writes, optional cache clearing, and loop mode.
- Create `root/etc/init.d/tailscale-adguard-dns`: independent procd service for the DNS switch loop.
- Create `tests/tailscale_adguard_dns_switch_test.sh`: shell tests with fake `uci`, `nslookup`, `curl`, `logger`, `netstat`, `pgrep`, and `ubus` commands.
- Modify `root/etc/config/tailscale`: add disabled-by-default AdGuard DNS switch settings.
- Modify `htdocs/luci-static/resources/view/tailscale/setting.js`: add `AdGuard DNS` tab, settings, password placeholder behavior, and read-only preflight panel.
- Modify `root/usr/share/rpcd/acl.d/luci-app-tailscale.json`: allow LuCI to run the preflight command.
- Modify `Makefile`: add `+curl` runtime dependency.
- Modify `README.md`: document the feature, required environment, and rollback.

## API Notes

AdGuard Home documents:

- `GET /control/status` for global status.
- `GET /control/dns_info` for DNS settings, including `upstream_dns`.
- `POST /control/dns_config` for persistent DNS settings updates, including `upstream_dns`.
- `POST /control/test_upstream_dns` for non-persistent authenticated POST validation.

The script must preserve the current `dns_info` JSON and replace only the `upstream_dns` array before POSTing it back. The implementation uses `jq` for JSON handling and declares it as a package dependency.

Preflight must not persistently write `/control/dns_config`. It verifies authenticated POST capability with AdGuard Home's non-persistent `/control/test_upstream_dns` endpoint.

Cache clear uses `POST /control/cache_clear` when enabled. If this endpoint is unavailable on a given AdGuard Home build, the script logs a warning and leaves the new profile active.

## Task 1: Add Failing Tests For Profile, Health, Preflight, And API Payloads

**Files:**
- Create: `/Users/jearton/projects/litata/luci-app-tailscale/tests/tailscale_adguard_dns_switch_test.sh`

- [ ] **Step 1: Create the test file with fake commands**

```sh
#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_adguard_dns_switch"
TMP_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"

	[ "$expected" = "$actual" ] || fail "$message
expected: $expected
actual:   $actual"
}

assert_contains() {
	local needle="$1"
	local haystack="$2"
	local message="$3"

	printf '%s' "$haystack" | grep -F "$needle" >/dev/null || fail "$message
missing: $needle
actual:  $haystack"
}

make_fake_uci() {
	cat >"$TMP_DIR/uci" <<'EOF'
#!/bin/sh
case "$*" in
	"-q get tailscale.settings.adguard_dns_switch_enabled") echo "${UCI_SWITCH_ENABLED:-1}" ;;
	"-q get tailscale.settings.accept_dns") echo "${UCI_ACCEPT_DNS:-1}" ;;
	"-q get tailscale.settings.adguard_api_url") echo "${UCI_API_URL:-http://127.0.0.1:3000}" ;;
	"-q get tailscale.settings.adguard_username") echo "${UCI_API_USER:-}" ;;
	"-q get tailscale.settings.adguard_password") echo "${UCI_API_PASS:-}" ;;
	"-q get tailscale.settings.adguard_health_domain") echo "${UCI_HEALTH_DOMAIN:-sso.litata.com}" ;;
	"-q get tailscale.settings.adguard_health_dns") echo "${UCI_HEALTH_DNS:-100.100.100.100}" ;;
	"-q get tailscale.settings.adguard_check_interval") echo "${UCI_CHECK_INTERVAL:-10}" ;;
	"-q get tailscale.settings.adguard_success_threshold") echo "${UCI_SUCCESS_THRESHOLD:-2}" ;;
	"-q get tailscale.settings.adguard_failure_threshold") echo "${UCI_FAILURE_THRESHOLD:-2}" ;;
	"-q get tailscale.settings.adguard_clear_cache") echo "${UCI_CLEAR_CACHE:-1}" ;;
	"-q get network.lan.ipaddr") echo "${UCI_LAN_IP:-192.168.100.1}" ;;
	"-q get dhcp.lan.dhcp_option") echo "${UCI_DHCP_OPTIONS:-6,192.168.100.1}" ;;
	"show tailscale.settings.adguard_default_upstreams")
		echo "tailscale.settings.adguard_default_upstreams='[/lan/]127.0.0.1:5353'"
		echo "tailscale.settings.adguard_default_upstreams='223.5.5.5'"
		echo "tailscale.settings.adguard_default_upstreams='119.29.29.29'"
		;;
	"show tailscale.settings.adguard_tailnet_upstreams")
		echo "tailscale.settings.adguard_tailnet_upstreams='[/litata.tailnet/]100.100.100.100'"
		echo "tailscale.settings.adguard_tailnet_upstreams='[/litata.com/]100.100.100.100'"
		;;
	"show tailscale.settings.adguard_health_expected_ips")
		echo "tailscale.settings.adguard_health_expected_ips='10.10.6.156'"
		;;
	*) exit 1 ;;
esac
EOF
	chmod +x "$TMP_DIR/uci"
}

make_fake_commands() {
	make_fake_uci

	cat >"$TMP_DIR/nslookup" <<'EOF'
#!/bin/sh
if [ "${NSLOOKUP_HEALTH:-ok}" = "ok" ]; then
	cat <<OUT
Server:		100.100.100.100
Address:	100.100.100.100:53
Name:	sso.litata.com
Address: 10.10.6.156
OUT
else
	cat <<OUT
Server:		100.100.100.100
Address:	100.100.100.100:53
** server can't find sso.litata.com: SERVFAIL
OUT
	exit 1
fi
EOF
	chmod +x "$TMP_DIR/nslookup"

	cat >"$TMP_DIR/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${CURL_LOG:?}"
case "$*" in
	*"/control/status"*) echo '{"running":true,"dns_port":53}' ;;
	*"/control/dns_info"*) cat "${DNS_INFO_JSON:?}" ;;
	*"/control/dns_config"*) cat >"${POSTED_JSON:?}"; echo OK ;;
	*"/control/cache_clear"*) echo OK ;;
	*) echo OK ;;
esac
EOF
	chmod +x "$TMP_DIR/curl"

	cat >"$TMP_DIR/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
EOF
	chmod +x "$TMP_DIR/logger"

	cat >"$TMP_DIR/pgrep" <<'EOF'
#!/bin/sh
[ "${PGREP_ADGUARD:-1}" = "1" ] && exit 0
exit 1
EOF
	chmod +x "$TMP_DIR/pgrep"

	cat >"$TMP_DIR/netstat" <<'EOF'
#!/bin/sh
if [ "${NETSTAT_ADGUARD_53:-1}" = "1" ]; then
	echo "udp        0      0 0.0.0.0:53              0.0.0.0:*                           1234/AdGuardHome"
else
	echo "udp        0      0 0.0.0.0:53              0.0.0.0:*                           1234/dnsmasq"
fi
EOF
	chmod +x "$TMP_DIR/netstat"

	cat >"$TMP_DIR/ubus" <<'EOF'
#!/bin/sh
cat <<OUT
{"ipv4-address":[{"address":"192.168.100.1","mask":24}]}
OUT
EOF
	chmod +x "$TMP_DIR/ubus"

	PATH="$TMP_DIR:$PATH"
	export PATH
}

prepare_api_json() {
	CURL_LOG="$TMP_DIR/curl.log"
	LOGGER_LOG="$TMP_DIR/logger.log"
	DNS_INFO_JSON="$TMP_DIR/dns-info.json"
	POSTED_JSON="$TMP_DIR/posted.json"
	export CURL_LOG LOGGER_LOG DNS_INFO_JSON POSTED_JSON

	cat >"$DNS_INFO_JSON" <<'EOF'
{"upstream_dns":["1.1.1.1"],"bootstrap_dns":["223.5.5.5"],"fallback_dns":["119.29.29.29"],"cache_enabled":false,"cache_size":4194304}
EOF
}

run_script() {
	"$SCRIPT" "$@"
}

test_profile_generation() {
	local up down

	up="$(run_script --profile up)"
	down="$(run_script --profile down)"

	assert_eq "[/lan/]127.0.0.1:5353
[/litata.tailnet/]100.100.100.100
[/litata.com/]100.100.100.100
223.5.5.5
119.29.29.29" "$up" "up profile should merge tailnet conditionals before public DNS"
	assert_eq "[/lan/]127.0.0.1:5353
223.5.5.5
119.29.29.29" "$down" "down profile should contain default upstreams only"
}

test_health_check() {
	NSLOOKUP_HEALTH=ok run_script --check-health >/dev/null
	if NSLOOKUP_HEALTH=fail run_script --check-health >/dev/null 2>&1; then
		fail "failed nslookup must make health check fail"
	fi
}

test_preflight_reports_failures() {
	local out

	out="$(NETSTAT_ADGUARD_53=0 run_script --preflight || true)"
	assert_contains "port_53_adguard=fail" "$out" "preflight should report port 53 ownership failure"
	assert_contains "ready=fail" "$out" "preflight should not be ready when a required check fails"
}

test_apply_profile_preserves_dns_info() {
	run_script --apply-profile up

	assert_contains '"bootstrap_dns":["223.5.5.5"]' "$(cat "$POSTED_JSON")" "API payload should preserve bootstrap_dns"
	assert_contains '"fallback_dns":["119.29.29.29"]' "$(cat "$POSTED_JSON")" "API payload should preserve fallback_dns"
	assert_contains '"upstream_dns":["[/lan/]127.0.0.1:5353","[/litata.tailnet/]100.100.100.100","[/litata.com/]100.100.100.100","223.5.5.5","119.29.29.29"]' "$(cat "$POSTED_JSON")" "API payload should replace upstream_dns"
}

make_fake_commands
prepare_api_json

test_profile_generation
test_health_check
test_preflight_reports_failures
test_apply_profile_preserves_dns_info

echo "tailscale_adguard_dns_switch tests passed"
```

- [ ] **Step 2: Run the new test and verify it fails before implementation**

Run:

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
sh tests/tailscale_adguard_dns_switch_test.sh
```

Expected:

```text
tests/tailscale_adguard_dns_switch_test.sh: ... root/usr/sbin/tailscale_adguard_dns_switch: not found
```

## Task 2: Implement The Switch Script

**Files:**
- Create: `/Users/jearton/projects/litata/luci-app-tailscale/root/usr/sbin/tailscale_adguard_dns_switch`

- [ ] **Step 1: Create the runtime script**

```sh
#!/bin/sh

# Copyright (C) 2026 jearton
# SPDX-License-Identifier: GPL-3.0-only

UCI_CMD="${UCI_CMD:-uci}"
CURL_CMD="${CURL_CMD:-curl}"
JQ_CMD="${JQ_CMD:-jq}"
LOGGER_CMD="${LOGGER_CMD:-logger}"
NSLOOKUP_CMD="${NSLOOKUP_CMD:-nslookup}"
PGREP_CMD="${PGREP_CMD:-pgrep}"
NETSTAT_CMD="${NETSTAT_CMD:-netstat}"
UBUS_CMD="${UBUS_CMD:-ubus}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"
DATE_CMD="${DATE_CMD:-date}"
STATE_DIR="${STATE_DIR:-/tmp/tailscale_adguard_dns_switch}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-10}"
TAG="tailscale_adguard_dns"

log_msg() {
	local priority="$1"
	local message="$2"
	"$LOGGER_CMD" -p "$priority" -t "$TAG" "$message"
}

uci_get() {
	"$UCI_CMD" -q get "tailscale.settings.$1" 2>/dev/null || true
}

uci_list() {
	local option="$1"
	"$UCI_CMD" show "tailscale.settings.$option" 2>/dev/null | sed -n "s/^tailscale\\.settings\\.$option='\\(.*\\)'$/\\1/p"
}

enabled() {
	[ "$(uci_get adguard_dns_switch_enabled)" = "1" ]
}

dedupe_lines() {
	awk 'NF && !seen[$0]++'
}

default_upstreams() {
	uci_list adguard_default_upstreams
}

tailnet_upstreams() {
	uci_list adguard_tailnet_upstreams
}

profile_lines() {
	local profile="$1"

	case "$profile" in
		up)
			{
				default_upstreams | sed '/100\.100\.100\.100/d'
				tailnet_upstreams
				default_upstreams | grep -F '100.100.100.100' || true
			} | dedupe_lines
			;;
		down)
			default_upstreams | sed '/100\.100\.100\.100/d' | dedupe_lines
			;;
		*)
			echo "unknown profile: $profile" >&2
			return 2
			;;
	esac
}

expected_ips() {
	uci_list adguard_health_expected_ips
}

health_domain() {
	uci_get adguard_health_domain
}

health_dns() {
	local dns
	dns="$(uci_get adguard_health_dns)"
	[ -n "$dns" ] && printf '%s\n' "$dns" || printf '%s\n' "100.100.100.100"
}

check_health() {
	local domain dns output expected

	domain="$(health_domain)"
	dns="$(health_dns)"
	[ -n "$domain" ] || return 1
	[ -n "$(expected_ips)" ] || return 1

	output="$("$NSLOOKUP_CMD" "$domain" "$dns" 2>&1)" || return 1
	for expected in $(expected_ips); do
		printf '%s\n' "$output" | awk -v ip="$expected" '
			$0 ~ ("(^|[^0-9.])" ip "([^0-9.]|$)") { found=1 }
			END { exit found ? 0 : 1 }
		' && return 0
	done

	return 1
}

api_url() {
	local url
	url="$(uci_get adguard_api_url)"
	[ -n "$url" ] && printf '%s\n' "${url%/}" || printf '%s\n' "http://127.0.0.1:3000"
}

curl_auth_args() {
	local user pass

	user="$(uci_get adguard_username)"
	pass="$(uci_get adguard_password)"
	[ -n "$user" ] || return 0
	printf '%s\n' "-u"
	printf '%s\n' "$user:$pass"
}

curl_get() {
	local endpoint="$1"
	local base auth

	base="$(api_url)"
	auth="$(curl_auth_args)"
	# shellcheck disable=SC2086
	"$CURL_CMD" -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" $auth "$base$endpoint"
}

curl_post_json() {
	local endpoint="$1"
	local body_file="$2"
	local base auth

	base="$(api_url)"
	auth="$(curl_auth_args)"
	# shellcheck disable=SC2086
	"$CURL_CMD" -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" $auth -H "Content-Type: application/json" -X POST --data-binary "@$body_file" "$base$endpoint"
}

json_extract_upstreams_body() {
	local dns_info="$1"

	"$JQ_CMD" -c -e '
		if (.upstream_dns | type) == "array" then
			{upstream_dns: .upstream_dns}
		else
			error("missing upstream_dns")
		end
	' "$dns_info"
}

check_adguard_api() {
	local api_check_info api_check_body

	mkdir -p "$STATE_DIR"
	api_check_info="$STATE_DIR/preflight_dns_info.json"
	api_check_body="$STATE_DIR/preflight_test_upstream_dns.json"

	curl_get "/control/status" >/dev/null || return 1
	curl_get "/control/dns_info" >"$api_check_info" || return 1
	[ -s "$api_check_info" ] || return 1
	json_extract_upstreams_body "$api_check_info" >"$api_check_body" || return 1
	curl_post_json "/control/test_upstream_dns" "$api_check_body" >/dev/null || return 1
}

json_replace_upstreams() {
	local dns_info="$1"
	local upstream_file="$2"

	"$JQ_CMD" -c --rawfile upstreams "$upstream_file" '
		.upstream_dns = ($upstreams | split("\n") | map(select(length > 0)))
	' "$dns_info"
}

apply_profile() {
	local profile="$1"
	local dns_info body upstreams

	mkdir -p "$STATE_DIR"
	dns_info="$STATE_DIR/dns_info.json"
	body="$STATE_DIR/dns_config.json"
	upstreams="$STATE_DIR/upstreams.txt"

	profile_lines "$profile" >"$upstreams"
	[ -s "$upstreams" ] || {
		log_msg daemon.err "generated AdGuard DNS $profile profile is empty"
		return 1
	}
	curl_get "/control/dns_info" >"$dns_info" || {
		log_msg daemon.err "failed to read AdGuard DNS config"
		return 1
	}
	json_replace_upstreams "$dns_info" "$upstreams" >"$body" || {
		log_msg daemon.err "failed to build AdGuard DNS config payload"
		return 1
	}
	curl_post_json "/control/dns_config" "$body" >/dev/null || {
		log_msg daemon.err "failed to write AdGuard DNS $profile profile"
		return 1
	}

	if [ "$(uci_get adguard_clear_cache)" = "1" ]; then
		curl_post_json "/control/cache_clear" /dev/null >/dev/null 2>&1 || \
			log_msg daemon.warn "AdGuard cache clear failed after $profile profile switch"
	fi

	printf '%s\n' "$profile" >"$STATE_DIR/current_profile"
	log_msg daemon.info "applied AdGuard DNS $profile profile"
}

lan_ip() {
	local ip

	ip="$("$UBUS_CMD" call network.interface.lan status 2>/dev/null | sed -n 's/.*"address":"\([0-9.]*\)".*/\1/p' | head -n 1)"
	[ -n "$ip" ] && {
		printf '%s\n' "$ip"
		return 0
	}

	"$UCI_CMD" -q get network.lan.ipaddr 2>/dev/null || true
}

check_dhcp_option() {
	local ip options

	ip="$(lan_ip)"
	options="$("$UCI_CMD" -q get dhcp.lan.dhcp_option 2>/dev/null || true)"
	[ -n "$ip" ] || return 1
	printf '%s\n' "$options" | grep -Eq "(^|[[:space:]])6,$ip($|[[:space:]])"
}

check_port_53_adguard() {
	"$NETSTAT_CMD" -lnup 2>/dev/null | grep -E '[:.]53[[:space:]]' | grep -F 'AdGuardHome' >/dev/null
}

preflight() {
	local ready=pass
	local item

	for item in adguard_process port_53_adguard dhcp_advertises_lan_dns adguard_api accept_dns health_check; do
		case "$item" in
			adguard_process) "$PGREP_CMD" -f AdGuardHome >/dev/null 2>&1 ;;
			port_53_adguard) check_port_53_adguard ;;
			dhcp_advertises_lan_dns) check_dhcp_option ;;
			adguard_api) check_adguard_api ;;
			accept_dns) [ "$(uci_get accept_dns)" = "1" ] ;;
			health_check) check_health ;;
		esac
		if [ "$?" -eq 0 ]; then
			printf '%s=pass\n' "$item"
		else
			printf '%s=fail\n' "$item"
			ready=fail
		fi
	done

	printf 'ready=%s\n' "$ready"
	[ "$ready" = "pass" ]
}

run_loop() {
	local interval success_threshold failure_threshold success_count=0 failure_count=0 current desired

	enabled || {
		log_msg daemon.info "AdGuard DNS auto switch disabled"
		return 0
	}
	preflight >/dev/null || {
		log_msg daemon.err "AdGuard DNS auto switch preflight failed"
		return 1
	}

	interval="$(uci_get adguard_check_interval)"
	success_threshold="$(uci_get adguard_success_threshold)"
	failure_threshold="$(uci_get adguard_failure_threshold)"
	[ -n "$interval" ] || interval=10
	[ -n "$success_threshold" ] || success_threshold=2
	[ -n "$failure_threshold" ] || failure_threshold=2
	mkdir -p "$STATE_DIR"

	while :; do
		current="$(cat "$STATE_DIR/current_profile" 2>/dev/null || true)"
		if check_health; then
			success_count=$((success_count + 1))
			failure_count=0
			desired=up
			[ "$success_count" -ge "$success_threshold" ] || desired="$current"
		else
			failure_count=$((failure_count + 1))
			success_count=0
			desired=down
			[ "$failure_count" -ge "$failure_threshold" ] || desired="$current"
		fi

		if [ -n "$desired" ] && [ "$desired" != "$current" ]; then
			apply_profile "$desired" || true
		fi

		"$SLEEP_CMD" "$interval"
	done
}

case "${1:-}" in
	--profile)
		profile_lines "${2:-}"
		;;
	--check-health)
		check_health
		;;
	--preflight)
		preflight
		;;
	--apply-profile)
		apply_profile "${2:-}"
		;;
	--run)
		run_loop
		;;
	*)
		echo "usage: $0 --profile up|down | --check-health | --preflight | --apply-profile up|down | --run" >&2
		exit 2
		;;
esac
```

- [ ] **Step 2: Make the script executable and run the tests**

Run:

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
chmod +x root/usr/sbin/tailscale_adguard_dns_switch
sh tests/tailscale_adguard_dns_switch_test.sh
```

Expected:

```text
tailscale_adguard_dns_switch tests passed
```

- [ ] **Step 3: Commit script and tests**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
git add root/usr/sbin/tailscale_adguard_dns_switch tests/tailscale_adguard_dns_switch_test.sh
git commit -m "Add AdGuard DNS switch runtime"
```

## Task 3: Add UCI Defaults And procd Service

**Files:**
- Modify: `/Users/jearton/projects/litata/luci-app-tailscale/root/etc/config/tailscale`
- Create: `/Users/jearton/projects/litata/luci-app-tailscale/root/etc/init.d/tailscale-adguard-dns`

- [ ] **Step 1: Add disabled-by-default config to `root/etc/config/tailscale`**

Add this block after the keepalive options:

```uci
	# Enable AdGuard Home DNS upstream auto switching based on Tailnet DNS health
	#option adguard_dns_switch_enabled '0'
	# Default AdGuard upstreams used when Tailnet DNS is unhealthy
	#list adguard_default_upstreams '[/lan/]127.0.0.1:5353'
	#list adguard_default_upstreams '223.5.5.5'
	#list adguard_default_upstreams '223.6.6.6'
	#list adguard_default_upstreams '119.29.29.29'
	# Tailnet conditional upstreams added when Tailnet DNS is healthy
	#list adguard_tailnet_upstreams '[/litata.tailnet/]100.100.100.100'
	#list adguard_tailnet_upstreams '[/litata.com/]100.100.100.100'
	# Domain that proves Tailnet DNS is healthy
	#option adguard_health_domain ''
	# DNS server used for the Tailnet DNS health check
	option adguard_health_dns '100.100.100.100'
	# Expected IPs for the Tailnet DNS health check
	#list adguard_health_expected_ips ''
	# Seconds between health checks
	option adguard_check_interval '10'
	# Successful checks required before switching to the up profile
	option adguard_success_threshold '2'
	# Failed checks required before switching to the down profile
	option adguard_failure_threshold '2'
	# Clear AdGuard DNS cache after profile changes
	option adguard_clear_cache '1'
	# AdGuard Home API base URL
	option adguard_api_url 'http://127.0.0.1:3000'
	# AdGuard Home API username and password, if authentication is enabled
	#option adguard_username ''
	#option adguard_password ''
```

- [ ] **Step 2: Create the independent init script**

```sh
#!/bin/sh /etc/rc.common

START=95
USE_PROCD=1

PROG=/usr/sbin/tailscale_adguard_dns_switch

service_triggers() {
	procd_add_reload_trigger "tailscale"
}

start_service() {
	local enabled std_out std_err

	config_load tailscale
	config_get_bool enabled settings adguard_dns_switch_enabled 0
	[ "$enabled" = "1" ] || {
		echo "disabled in /etc/config/tailscale"
		return 0
	}

	config_get_bool std_out settings log_stdout 1
	config_get_bool std_err settings log_stderr 1

	procd_open_instance
	procd_set_param command "$PROG" --run
	procd_set_param respawn
	procd_set_param stdout "$std_out"
	procd_set_param stderr "$std_err"
	procd_close_instance
}
```

- [ ] **Step 3: Make the init script executable and run syntax checks**

Run:

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
chmod +x root/etc/init.d/tailscale-adguard-dns
sh -n root/etc/init.d/tailscale-adguard-dns
sh -n root/usr/sbin/tailscale_adguard_dns_switch
```

Expected: no output and exit code 0.

- [ ] **Step 4: Commit config and service**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
git add root/etc/config/tailscale root/etc/init.d/tailscale-adguard-dns
git commit -m "Add AdGuard DNS switch service"
```

## Task 4: Add LuCI Configuration And Preflight Status

**Files:**
- Modify: `/Users/jearton/projects/litata/luci-app-tailscale/htdocs/luci-static/resources/view/tailscale/setting.js`
- Modify: `/Users/jearton/projects/litata/luci-app-tailscale/root/usr/share/rpcd/acl.d/luci-app-tailscale.json`

- [ ] **Step 1: Load preflight data**

In `load()`, append the preflight command and tolerate missing script errors:

```js
fs.exec("/usr/sbin/tailscale_adguard_dns_switch", ["--preflight"]).catch(function(e) {
	return { stdout: "ready=fail\nerror=" + (e.message || e) + "\n" };
})
```

The full `Promise.all()` becomes:

```js
return Promise.all([
	uci.load('tailscale'),
	getStatus(),
	getInterfaceSubnets(),
	fs.exec("/usr/sbin/tailscale_adguard_dns_switch", ["--preflight"]).catch(function(e) {
		return { stdout: "ready=fail\nerror=" + (e.message || e) + "\n" };
	})
]);
```

- [ ] **Step 2: Add parser and renderer helpers before `return view.extend`**

```js
function parseKeyValues(value) {
	const out = {};
	String(value || '').split(/\n/).forEach(function(line) {
		const idx = line.indexOf('=');
		if (idx > 0)
			out[line.slice(0, idx)] = line.slice(idx + 1);
	});
	return out;
}

function renderCheck(value) {
	const ok = value === 'pass';
	return E('span', { style: 'color:' + (ok ? 'green' : 'red') }, ok ? _('Pass') : _('Fail'));
}
```

- [ ] **Step 3: Add the `AdGuard DNS` tab**

After the keepalive options and before `s.tab('extra', ...)`, add:

```js
s.tab('adguard_dns', _('AdGuard DNS'));

const adguardPreflight = parseKeyValues((data[3] || {}).stdout);
const hasAdguardPassword = !!uci.get('tailscale', 'settings', 'adguard_password');

o = s.taboption('adguard_dns', form.DummyValue, '_adguard_dns_status', _('Status'));
o.rawhtml = true;
o.renderWidget = function() {
	return E('div', { class: 'table' }, [
		E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('AdGuard process')), E('div', { class: 'td' }, renderCheck(adguardPreflight.adguard_process))]),
		E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('Port 53 is AdGuard')), E('div', { class: 'td' }, renderCheck(adguardPreflight.port_53_adguard))]),
		E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('LAN DHCP advertises this router as DNS')), E('div', { class: 'td' }, renderCheck(adguardPreflight.dhcp_advertises_lan_dns))]),
		E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('AdGuard API')), E('div', { class: 'td' }, renderCheck(adguardPreflight.adguard_api))]),
		E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('Tailscale Accept DNS')), E('div', { class: 'td' }, renderCheck(adguardPreflight.accept_dns))]),
		E('div', { class: 'tr' }, [E('div', { class: 'td left' }, _('Tailnet DNS health check')), E('div', { class: 'td' }, renderCheck(adguardPreflight.health_check))])
	]);
};

o = s.taboption('adguard_dns', form.Flag, 'adguard_dns_switch_enabled', _('Enable AdGuard DNS Auto Switch'), _('Only enable when all status checks pass.'));
o.default = o.disabled;
o.rmempty = false;
o.validate = function(section_id, value) {
	if (value === '1' && adguardPreflight.ready !== 'pass')
		return _('AdGuard DNS auto switch cannot be enabled until every status check passes.');
	return true;
};

o = s.taboption('adguard_dns', form.DynamicList, 'adguard_default_upstreams', _('Default Upstreams'), _('Used when Tailnet DNS is unhealthy.'));
o.default = '';
o.rmempty = true;

o = s.taboption('adguard_dns', form.DynamicList, 'adguard_tailnet_upstreams', _('Tailnet Upstreams'), _('Added when Tailnet DNS is healthy.'));
o.default = '';
o.rmempty = true;

o = s.taboption('adguard_dns', form.Value, 'adguard_health_domain', _('Health Check Domain'));
o.datatype = 'hostname';
o.rmempty = true;

o = s.taboption('adguard_dns', form.Value, 'adguard_health_dns', _('Health Check DNS Server'));
o.datatype = 'ipaddr';
o.default = '100.100.100.100';
o.rmempty = false;

o = s.taboption('adguard_dns', form.DynamicList, 'adguard_health_expected_ips', _('Expected Health IPs'));
o.default = '';
o.rmempty = true;

o = s.taboption('adguard_dns', form.Value, 'adguard_check_interval', _('Check Interval'));
o.datatype = 'uinteger';
o.default = '10';
o.rmempty = false;

o = s.taboption('adguard_dns', form.Value, 'adguard_success_threshold', _('Success Threshold'));
o.datatype = 'uinteger';
o.default = '2';
o.rmempty = false;

o = s.taboption('adguard_dns', form.Value, 'adguard_failure_threshold', _('Failure Threshold'));
o.datatype = 'uinteger';
o.default = '2';
o.rmempty = false;

o = s.taboption('adguard_dns', form.Flag, 'adguard_clear_cache', _('Clear AdGuard Cache After Switch'));
o.default = o.enabled;
o.rmempty = false;

o = s.taboption('adguard_dns', form.Value, 'adguard_api_url', _('AdGuard API URL'));
o.default = 'http://127.0.0.1:3000';
o.rmempty = false;

o = s.taboption('adguard_dns', form.Value, 'adguard_username', _('AdGuard Username'));
o.default = '';
o.rmempty = true;

o = s.taboption('adguard_dns', form.Value, 'adguard_password', _('AdGuard Password'));
o.password = true;
o.default = '';
o.rmempty = true;
o.placeholder = hasAdguardPassword ? _('Configured; leave blank to keep existing value.') : '';
o.description = hasAdguardPassword ? _('Configured; leave blank to keep existing value.') : '';
o.cfgvalue = function() {
	return '';
};
o.write = function(section_id, value) {
	value = (value || '').trim();
	if (value)
		return uci.set('tailscale', section_id, 'adguard_password', value);
};
o.remove = function() {};
```

- [ ] **Step 4: Update ACL**

Add this command to `root/usr/share/rpcd/acl.d/luci-app-tailscale.json` under `file.exec`:

```json
"/usr/sbin/tailscale_adguard_dns_switch --preflight"
```

- [ ] **Step 5: Run syntax-oriented checks**

Run:

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
node --check htdocs/luci-static/resources/view/tailscale/setting.js
python3 -m json.tool root/usr/share/rpcd/acl.d/luci-app-tailscale.json >/dev/null
```

Expected: no output and exit code 0.

- [ ] **Step 6: Commit LuCI changes**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
git add htdocs/luci-static/resources/view/tailscale/setting.js root/usr/share/rpcd/acl.d/luci-app-tailscale.json
git commit -m "Add AdGuard DNS switch LuCI settings"
```

## Task 5: Update Package Metadata And Documentation

**Files:**
- Modify: `/Users/jearton/projects/litata/luci-app-tailscale/Makefile`
- Modify: `/Users/jearton/projects/litata/luci-app-tailscale/README.md`

- [ ] **Step 1: Add `curl` and `jq` dependencies**

Change:

```make
LUCI_DEPENDS:=+tailscale +jshn
```

to:

```make
LUCI_DEPENDS:=+tailscale +jshn +curl +jq
```

- [ ] **Step 2: Add README section**

Append:

```markdown
## AdGuard DNS Auto Switch

This package can optionally manage AdGuard Home upstream DNS servers based on Tailnet DNS health.

The feature is disabled by default. It is intended for OpenWrt routers where:

- AdGuard Home is running on the router.
- AdGuard Home owns LAN DNS on port 53.
- LAN DHCP advertises the router LAN IP as DNS, for example `6,192.168.100.1`.
- Tailscale uses `accept_dns=1`.
- Headscale or Tailscale DNS can answer an internal health-check record through `100.100.100.100`.

When healthy, the switch applies:

```text
default upstreams + Tailnet conditional upstreams
```

When unhealthy, the switch applies:

```text
default upstreams only
```

The switch writes through the AdGuard Home HTTP API and does not require the AdGuard YAML path in LuCI. If the AdGuard password field is left empty, the existing password is kept.

Rollback:

```sh
/etc/init.d/tailscale-adguard-dns stop
uci set tailscale.settings.adguard_dns_switch_enabled='0'
uci commit tailscale
/etc/init.d/tailscale-adguard-dns disable
```

Then set AdGuard Home upstream DNS manually in the AdGuard UI.
```

- [ ] **Step 3: Commit docs and metadata**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
git add Makefile README.md
git commit -m "Document AdGuard DNS switch setup"
```

## Task 6: Full Verification

**Files:**
- No code changes.

- [ ] **Step 1: Run all shell tests**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
sh tests/tailscale_keepalive_test.sh
sh tests/tailscale_adguard_dns_switch_test.sh
```

Expected:

```text
tailscale_keepalive tests passed
tailscale_adguard_dns_switch tests passed
```

- [ ] **Step 2: Run syntax checks**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
find root -type f \( -path '*/init.d/*' -o -path '*/usr/sbin/*' \) -exec sh -n {} \;
node --check htdocs/luci-static/resources/view/tailscale/setting.js
python3 -m json.tool root/usr/share/rpcd/acl.d/luci-app-tailscale.json >/dev/null
```

Expected: no output and exit code 0.

- [ ] **Step 3: Inspect git history and diff**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
git status --short
git log --oneline --decorate -5
git diff origin/codex/fix-openwrt-tailscale-luci...HEAD --stat
```

Expected:

- Working tree is clean.
- New commits include runtime, service, LuCI, and docs changes.
- Diff contains only the planned package files.

- [ ] **Step 4: Push branch**

```bash
cd /Users/jearton/projects/litata/luci-app-tailscale
git push origin codex/fix-openwrt-tailscale-luci
```

Expected:

```text
To github.com:jearton/luci-app-tailscale.git
   <old>..<new>  codex/fix-openwrt-tailscale-luci -> codex/fix-openwrt-tailscale-luci
```

## Task 7: OpenWrt Manual Verification Plan

**Files:**
- No repo changes.

This task is not executed until the user confirms with exact `ok`, because it touches a live router.

- [ ] **Step 1: Read current infrastructure doc first**

```bash
cd /Users/jearton/projects/litata/infra-docs
sed -n '1,260p' docs/infra/litata-current-infrastructure-status.md
```

Expected: read and state the relevant facts before any router operation.

- [ ] **Step 2: Read-only router preflight**

Use `/usr/bin/expect` to run only read commands on `root@192.168.100.1`:

```sh
/usr/sbin/tailscale_adguard_dns_switch --preflight
/usr/sbin/tailscale_adguard_dns_switch --profile up
/usr/sbin/tailscale_adguard_dns_switch --profile down
tailscale dns status
nslookup sso.litata.com 100.100.100.100
nslookup tailscale.litata.com 100.100.100.100
nslookup deploy.litata.com 100.100.100.100
nslookup code.litata.com 100.100.100.100
```

Expected:

- Preflight prints all `pass`.
- Up/down profiles match LuCI configuration.
- Health domain resolves to a configured expected internal IP through `100.100.100.100`.

- [ ] **Step 3: Discuss live write plan and rollback with the user**

Write plan:

```sh
opkg install --force-overwrite /tmp/luci-app-tailscale_*.ipk
/etc/init.d/rpcd reload
/etc/init.d/uhttpd reload
uci set tailscale.settings.adguard_dns_switch_enabled='1'
uci commit tailscale
/etc/init.d/tailscale-adguard-dns enable
/etc/init.d/tailscale-adguard-dns restart
```

Rollback:

```sh
/etc/init.d/tailscale-adguard-dns stop
uci set tailscale.settings.adguard_dns_switch_enabled='0'
uci commit tailscale
/etc/init.d/tailscale-adguard-dns disable
```

Only execute after the user replies `ok`.

- [ ] **Step 4: Verify after live enablement**

```sh
/etc/init.d/tailscale-adguard-dns status
logread -e tailscale_adguard_dns
nslookup sso.litata.com 127.0.0.1
nslookup tailscale.litata.com 127.0.0.1
nslookup deploy.litata.com 127.0.0.1
nslookup code.litata.com 127.0.0.1
```

Expected while Tailscale is up:

- `sso.litata.com` returns the Headscale DNS Record internal IP.
- `tailscale.litata.com` returns the Headscale DNS Record internal IP.
- `deploy.litata.com` resolves through public DNS behavior.
- `code.litata.com` returns the Headscale DNS Record internal IP.

Expected after deliberately stopping Tailscale and allowing failure threshold:

- `sso.litata.com` returns public DNS behavior.
- `tailscale.litata.com` returns public DNS behavior.
- `deploy.litata.com` resolves through public DNS behavior.
- `code.litata.com` returns public DNS behavior, including NXDOMAIN if no public record exists.

## Self-Review

- Spec coverage:
  - Optional feature: Task 3 defaults disabled and service only starts when enabled.
  - No native Tailscale DNS behavior changes: no task edits `/etc/resolv.conf`, `tailscale_helper`, or `tailscale up`.
  - Profiles: Task 1 and Task 2 cover up/down profile generation.
  - Health check and thresholds: Task 2 implements `--check-health` and loop hysteresis; Task 1 covers health parsing.
  - Strong enablement checks: Task 2 implements preflight; Task 4 blocks LuCI enablement; Task 7 verifies on router before writes.
  - AdGuard API integration: Task 2 reads `dns_info`, preserves JSON, replaces only `upstream_dns`, writes `dns_config`, and attempts cache clear.
  - LuCI fields: Task 4 adds every field listed in the spec.
  - Cache policy: Task 2 supports cache clear after profile changes; Task 5 documents cache implications.
  - Tests: Task 1 and Task 6 cover new and existing shell tests.
- Placeholder scan:
  - No placeholder markers or deferred-work wording remain.
  - Code-changing steps include exact code blocks and commands.
- Consistency:
  - UCI option names are consistent across config, script, and LuCI.
  - Script subcommands used by LuCI and tests are `--preflight`, `--profile`, `--check-health`, `--apply-profile`, and `--run`.
  - Runtime state path is `/tmp/tailscale_adguard_dns_switch`.
