#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_adguard_dns_switch"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-adguard-dns-test.$$"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_eq() {
	expected="$1"
	actual="$2"
	message="$3"

	[ "$expected" = "$actual" ] || fail "$message
expected: $expected
actual:   $actual"
}

assert_contains() {
	needle="$1"
	haystack="$2"
	message="$3"

	printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null || fail "$message
missing: $needle
actual:  $haystack"
}

assert_occurrences() {
	expected="$1"
	needle="$2"
	file="$3"
	message="$4"
	actual="$(grep -F -c -- "$needle" "$file" || true)"

	[ "$expected" = "$actual" ] || fail "$message
expected occurrences: $expected
actual occurrences:   $actual
needle: $needle"
}

make_fake_uci() {
	cat >"$TMP_DIR/uci" <<'SH'
#!/bin/sh
case "$*" in
	"-q get tailscale.settings.adguard_dns_switch_enabled") echo "${UCI_SWITCH_ENABLED:-1}" ;;
	"-q get tailscale.settings.accept_dns") echo "${UCI_ACCEPT_DNS:-1}" ;;
	"-q get tailscale.settings.adguard_api_url") echo "${UCI_API_URL:-http://127.0.0.1:3000}" ;;
	"-q get tailscale.settings.adguard_username") echo "${UCI_API_USER:-}" ;;
	"-q get tailscale.settings.adguard_password") echo "${UCI_API_PASS:-}" ;;
	"-q get tailscale.settings.adguard_health_domain") echo "${UCI_HEALTH_DOMAIN:-service.example.test}" ;;
	"-q get tailscale.settings.adguard_check_interval") echo "${UCI_CHECK_INTERVAL:-10}" ;;
	"-q get tailscale.settings.adguard_success_threshold") echo "${UCI_SUCCESS_THRESHOLD:-2}" ;;
	"-q get tailscale.settings.adguard_failure_threshold") echo "${UCI_FAILURE_THRESHOLD:-2}" ;;
	"-q get tailscale.settings.adguard_default_upstreams")
		[ "${UCI_EMPTY_DEFAULT_UPSTREAMS:-0}" = "1" ] && exit 1
		echo "[/lan/]127.0.0.1:5353 9.9.9.9 100.100.100.100 149.112.112.112 9.9.9.9"
		;;
	"-q get tailscale.settings.adguard_tailnet_upstreams")
		echo "[/example.ts.net/]100.100.100.100 [/internal.example/]100.100.100.100"
		;;
	"-q get tailscale.settings.adguard_health_expected_ips") echo "10.23.0.15" ;;
	"-q get network.lan.ipaddr") echo "${UCI_LAN_IP:-192.168.100.1}" ;;
	"-q get dhcp.lan.dhcp_option") echo "${UCI_DHCP_OPTIONS:-6,192.168.100.1}" ;;
	"show tailscale.settings.adguard_default_upstreams")
		[ "${UCI_EMPTY_DEFAULT_UPSTREAMS:-0}" = "1" ] && exit 0
		echo "tailscale.settings.adguard_default_upstreams='[/lan/]127.0.0.1:5353' '9.9.9.9' '100.100.100.100' '149.112.112.112' '9.9.9.9'"
		;;
	"show tailscale.settings.adguard_tailnet_upstreams")
		echo "tailscale.settings.adguard_tailnet_upstreams='[/example.ts.net/]100.100.100.100' '[/internal.example/]100.100.100.100'"
		;;
	"show tailscale.settings.adguard_health_expected_ips")
		echo "tailscale.settings.adguard_health_expected_ips='10.23.0.15'"
		;;
	*) exit 1 ;;
esac
SH
	chmod +x "$TMP_DIR/uci"
}

make_fake_commands() {
	make_fake_uci

	cat >"$TMP_DIR/nslookup" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${NSLOOKUP_LOG:?}"
if [ "${NSLOOKUP_HEALTH:-ok}" = "ok" ]; then
	cat <<'OUT'
Server:		100.100.100.100
Address:	100.100.100.100:53
Name:	service.example.test
Address: 10.23.0.15
OUT
else
	cat <<'OUT'
Server:		100.100.100.100
Address:	100.100.100.100:53
** server can't find service.example.test: SERVFAIL
OUT
	exit 1
fi
SH
	chmod +x "$TMP_DIR/nslookup"

	cat >"$TMP_DIR/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${CURL_LOG:?}"
case "$*" in
	*"/control/status"*) echo '{"running":true,"dns_port":53}' ;;
	*"/control/dns_info"*)
		[ "${CURL_DNS_INFO_FAIL:-0}" = "1" ] && exit 1
		cat "${DNS_INFO_JSON:?}"
		;;
	*"/control/dns_config"*)
		body=
		while [ "$#" -gt 0 ]; do
			if [ "$1" = "--data-binary" ]; then
				shift
				body="${1#@}"
			fi
			shift
		done
		[ "${CURL_DNS_CONFIG_FAIL:-0}" = "1" ] && exit 1
		[ -n "$body" ] && cat "$body" >"${POSTED_JSON:?}"
		echo OK
		;;
	*"/control/test_upstream_dns"*)
		body=
		while [ "$#" -gt 0 ]; do
			if [ "$1" = "--data-binary" ]; then
				shift
				body="${1#@}"
			fi
			shift
		done
		[ -n "$body" ] && cat "$body" >"${TEST_UPSTREAM_JSON:?}"
		[ "${CURL_TEST_UPSTREAM_FAIL:-0}" = "1" ] && exit 1
		echo OK
		;;
	*"/control/cache_clear"*)
		[ "${CURL_CACHE_CLEAR_FAIL:-0}" = "1" ] && exit 1
		echo OK
		;;
	*) echo OK ;;
esac
SH
	chmod +x "$TMP_DIR/curl"

	cat >"$TMP_DIR/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
	chmod +x "$TMP_DIR/logger"

cat >"$TMP_DIR/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${SLEEP_LOG:?}"
count_file="${SLEEP_COUNT_FILE:?}"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [ "$count" -ge "${SLEEP_MAX_CALLS:-1}" ]; then
	kill -TERM "$PPID"
fi
exit 0
SH
	chmod +x "$TMP_DIR/sleep"

	cat >"$TMP_DIR/pgrep" <<'SH'
#!/bin/sh
[ "${PGREP_ADGUARD:-1}" = "1" ] && exit 0
exit 1
SH
	chmod +x "$TMP_DIR/pgrep"

	cat >"$TMP_DIR/netstat" <<'SH'
#!/bin/sh
if [ "${NETSTAT_ADGUARD_53:-1}" = "1" ]; then
	echo "udp        0      0 0.0.0.0:53              0.0.0.0:*                           1234/AdGuardHome"
else
	echo "udp        0      0 0.0.0.0:53              0.0.0.0:*                           1234/dnsmasq"
fi
SH
	chmod +x "$TMP_DIR/netstat"

	cat >"$TMP_DIR/ubus" <<'SH'
#!/bin/sh
cat <<'OUT'
{"ipv4-address":[{"address":"192.168.100.1","mask":24}]}
OUT
SH
	chmod +x "$TMP_DIR/ubus"

cat >"$TMP_DIR/jq" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${JQ_LOG:?}"
[ "${JQ_REPLACE_FAIL:-0}" = "1" ] && printf '%s\n' "$*" | grep -F -- '--rawfile upstreams' >/dev/null && exit 1
exec "${REAL_JQ:?}" "$@"
SH
	chmod +x "$TMP_DIR/jq"

	PATH="$TMP_DIR:$PATH"
	export PATH
}

prepare_api_json() {
	CURL_LOG="$TMP_DIR/curl.log"
	LOGGER_LOG="$TMP_DIR/logger.log"
	DNS_INFO_JSON="$TMP_DIR/dns-info.json"
	POSTED_JSON="$TMP_DIR/posted.json"
	TEST_UPSTREAM_JSON="$TMP_DIR/test-upstream.json"
	JQ_LOG="$TMP_DIR/jq.log"
	NSLOOKUP_LOG="$TMP_DIR/nslookup-call.log"
	SLEEP_LOG="$TMP_DIR/sleep.log"
	SLEEP_COUNT_FILE="$TMP_DIR/sleep.count"
	REAL_JQ="${REAL_JQ:-$(command -v jq)}"
	STATE_DIR="$TMP_DIR/state"
	export CURL_LOG LOGGER_LOG DNS_INFO_JSON POSTED_JSON TEST_UPSTREAM_JSON JQ_LOG NSLOOKUP_LOG SLEEP_LOG SLEEP_COUNT_FILE REAL_JQ STATE_DIR
	printf '0\n' >"$SLEEP_COUNT_FILE"

	cat >"$DNS_INFO_JSON" <<'JSON'
{"upstream_dns":["1.1.1.1"],"bootstrap_dns":["223.5.5.5"],"fallback_dns":["119.29.29.29"],"cache_enabled":false,"cache_size":4194304}
JSON
}

run_script() {
	UCI_CMD="$TMP_DIR/uci" \
	CURL_CMD="$TMP_DIR/curl" \
	LOGGER_CMD="$TMP_DIR/logger" \
	NSLOOKUP_CMD="$TMP_DIR/nslookup" \
	PGREP_CMD="$TMP_DIR/pgrep" \
	NETSTAT_CMD="$TMP_DIR/netstat" \
	UBUS_CMD="$TMP_DIR/ubus" \
	JQ_CMD="$TMP_DIR/jq" \
	SLEEP_CMD="$TMP_DIR/sleep" \
	"$SCRIPT" "$@"
}

test_profile_generation() {
	up="$(run_script --profile up)"
	down="$(run_script --profile down)"

	assert_eq "[/lan/]127.0.0.1:5353
[/example.ts.net/]100.100.100.100
[/internal.example/]100.100.100.100
9.9.9.9
149.112.112.112
100.100.100.100" "$up" "up profile should place tailnet conditionals before public defaults"
	assert_eq "[/lan/]127.0.0.1:5353
9.9.9.9
149.112.112.112" "$down" "down profile should remove 100.100.100.100 and dedupe defaults"
}

test_health_check() {
	NSLOOKUP_HEALTH=ok run_script --check-health >/dev/null
	nslookup_call="$(cat "$TMP_DIR/nslookup-call.log")"
	assert_contains "service.example.test 100.100.100.100" "$nslookup_call" "health check must use hard-coded Tailscale DNS"
	if NSLOOKUP_HEALTH=fail run_script --check-health >/dev/null 2>&1; then
		fail "failed nslookup must make health check fail"
	fi
}

test_preflight_reports_failures() {
	out="$(NETSTAT_ADGUARD_53=0 run_script --preflight || true)"
	assert_contains "port_53_adguard=fail" "$out" "preflight should report port 53 ownership failure"
	assert_contains "ready=fail" "$out" "preflight should not be ready when a required check fails"
}

test_preflight_requires_api_post_test() {
	out="$(CURL_TEST_UPSTREAM_FAIL=1 run_script --preflight || true)"
	assert_contains "adguard_api=fail" "$out" "preflight should report AdGuard API test POST failure"
	assert_contains "ready=fail" "$out" "preflight should not be ready when AdGuard API test POST fails"

	if CURL_TEST_UPSTREAM_FAIL=1 run_script --preflight >/dev/null 2>&1; then
		fail "preflight should fail when AdGuard test_upstream_dns POST fails"
	fi
	if grep -F '/control/dns_config' "$CURL_LOG" >/dev/null; then
		fail "preflight must not POST to /control/dns_config"
	fi
	assert_contains "/control/test_upstream_dns" "$(cat "$CURL_LOG")" "preflight should POST to test_upstream_dns"
	assert_eq '{"upstream_dns":["[/lan/]127.0.0.1:5353","9.9.9.9","149.112.112.112"]}' "$(cat "$TEST_UPSTREAM_JSON")" "preflight API payload should come from configured default upstreams"
	assert_contains "--rawfile upstreams" "$(cat "$JQ_LOG")" "preflight API payload should be built from the validated upstream file with jq"
}

test_preflight_requires_configured_default_upstream() {
	: >"$LOGGER_LOG"
	out="$(UCI_EMPTY_DEFAULT_UPSTREAMS=1 run_script --preflight || true)"
	assert_contains "adguard_api=fail" "$out" "preflight should fail the API check when no default upstream is configured"
	assert_contains "ready=fail" "$out" "preflight should not be ready without a default upstream"
	assert_contains "requires at least one valid default upstream" "$(cat "$LOGGER_LOG")" "empty default upstream failure should be logged clearly"
}

test_preflight_does_not_require_accept_dns() {
	out="$(UCI_ACCEPT_DNS=0 run_script --preflight)"
	assert_contains "ready=pass" "$out" "preflight should pass when direct Tailscale DNS health checks work with accept_dns disabled"
	if printf '%s' "$out" | grep -F 'accept_dns=' >/dev/null; then
		fail "accept_dns should not be a blocking AdGuard DNS auto switch preflight check"
	fi
}

test_apply_profile_preserves_dns_info() {
	run_script --apply-profile up

	posted="$(cat "$POSTED_JSON")"
	assert_contains '"bootstrap_dns":["223.5.5.5"]' "$posted" "API payload should preserve bootstrap_dns"
	assert_contains '"fallback_dns":["119.29.29.29"]' "$posted" "API payload should preserve fallback_dns"
	assert_contains '"upstream_dns":["[/lan/]127.0.0.1:5353","[/example.ts.net/]100.100.100.100","[/internal.example/]100.100.100.100","9.9.9.9","149.112.112.112","100.100.100.100"]' "$posted" "API payload should replace upstream_dns"
	assert_contains "--rawfile upstreams" "$(cat "$JQ_LOG")" "profile application should use jq with raw upstream file input"
	assert_contains "--connect-timeout 3" "$(cat "$CURL_LOG")" "curl calls should include a connect timeout"
	assert_contains "--max-time 10" "$(cat "$CURL_LOG")" "curl calls should include a max time"
	assert_contains "/control/cache_clear" "$(cat "$CURL_LOG")" "profile application should always clear AdGuard cache after switching"
}

test_empty_profile_does_not_write_dns_config() {
	: >"$CURL_LOG"
	rm -f "$POSTED_JSON"

	if UCI_EMPTY_DEFAULT_UPSTREAMS=1 run_script --apply-profile down >/dev/null 2>&1; then
		fail "empty down profile should make apply-profile fail"
	fi
	if [ -e "$POSTED_JSON" ]; then
		fail "empty profile must not write dns_config payload"
	fi
	if grep -F '/control/dns_config' "$CURL_LOG" >/dev/null; then
		fail "empty profile must not POST to /control/dns_config"
	fi
}

test_run_loop_applies_down_profile_when_initial_health_fails() {
	: >"$CURL_LOG"
	: >"$SLEEP_LOG"
	rm -f "$POSTED_JSON"
	mkdir -p "$STATE_DIR"
	printf 'up\n' >"$STATE_DIR/current_profile"
	printf '0\n' >"$SLEEP_COUNT_FILE"

	UCI_FAILURE_THRESHOLD=1 NSLOOKUP_HEALTH=fail UCI_CHECK_INTERVAL=1 run_script --run >/dev/null 2>&1 || true

	posted="$(cat "$POSTED_JSON")"
	assert_contains '"upstream_dns":["[/lan/]127.0.0.1:5353","9.9.9.9","149.112.112.112"]' "$posted" "run loop should apply down profile when health initially fails"
	assert_contains "1" "$(cat "$SLEEP_LOG")" "run loop should continue after applying the down profile"
}

test_run_loop_retries_static_preflight_failures_without_exit_churn() {
	rm -rf "$STATE_DIR"
	mkdir -p "$STATE_DIR"
	: >"$LOGGER_LOG"
	: >"$SLEEP_LOG"
	printf '0\n' >"$SLEEP_COUNT_FILE"

	SLEEP_MAX_CALLS=3 NETSTAT_ADGUARD_53=0 UCI_CHECK_INTERVAL=1 run_script --run >/dev/null 2>&1 || true

	assert_eq "3" "$(cat "$SLEEP_COUNT_FILE")" "static preflight failure should stay in the worker and retry internally"
	assert_occurrences 1 "static preflight failed: port_53_adguard" "$LOGGER_LOG" "identical static preflight failures should be rate-limited without hiding the first"

	printf '0\n' >"$SLEEP_COUNT_FILE"
	SLEEP_MAX_CALLS=1 PGREP_ADGUARD=0 UCI_CHECK_INTERVAL=1 run_script --run >/dev/null 2>&1 || true
	assert_occurrences 1 "static preflight failed: adguard_process" "$LOGGER_LOG" "a different static preflight failure should log immediately"
}

test_profile_failures_are_rate_limited_by_signature() {
	rm -rf "$STATE_DIR"
	mkdir -p "$STATE_DIR"
	: >"$LOGGER_LOG"

	CURL_DNS_INFO_FAIL=1 run_script --apply-profile up >/dev/null 2>&1 || true
	CURL_DNS_INFO_FAIL=1 run_script --apply-profile up >/dev/null 2>&1 || true
	assert_occurrences 1 "failed to read AdGuard DNS config" "$LOGGER_LOG" "repeated profile read failures should be rate-limited"

	JQ_REPLACE_FAIL=1 run_script --apply-profile up >/dev/null 2>&1 || true
	JQ_REPLACE_FAIL=1 run_script --apply-profile up >/dev/null 2>&1 || true
	assert_occurrences 1 "failed to build AdGuard DNS config payload" "$LOGGER_LOG" "repeated profile build failures should be rate-limited"

	CURL_DNS_CONFIG_FAIL=1 run_script --apply-profile up >/dev/null 2>&1 || true
	CURL_DNS_CONFIG_FAIL=1 run_script --apply-profile up >/dev/null 2>&1 || true
	assert_occurrences 1 "failed to write AdGuard DNS up profile" "$LOGGER_LOG" "repeated profile write failures should be rate-limited"

	CURL_CACHE_CLEAR_FAIL=1 run_script --apply-profile up >/dev/null 2>&1
	CURL_CACHE_CLEAR_FAIL=1 run_script --apply-profile up >/dev/null 2>&1
	assert_occurrences 1 "AdGuard cache clear failed after up profile switch" "$LOGGER_LOG" "repeated cache-clear failures should be rate-limited"
}

mkdir -p "$TMP_DIR"
REAL_JQ="${REAL_JQ:-$(command -v jq)}"
export REAL_JQ
make_fake_commands
prepare_api_json

test_profile_generation
test_health_check
test_preflight_reports_failures
test_preflight_requires_api_post_test
test_preflight_requires_configured_default_upstream
test_preflight_does_not_require_accept_dns
test_apply_profile_preserves_dns_info
test_empty_profile_does_not_write_dns_config
test_run_loop_applies_down_profile_when_initial_health_fails
test_run_loop_retries_static_preflight_failures_without_exit_churn
test_profile_failures_are_rate_limited_by_signature

echo "tailscale_adguard_dns_switch tests passed"
