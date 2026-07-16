#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RPCD_SCRIPT="$ROOT_DIR/root/usr/libexec/rpcd/luci.tailscale"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-rpcd-test.$$"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$TMP_DIR"

cat >"$TMP_DIR/secrets" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${SECRETS_ARGV_LOG:?}"
case "${1:-}" in
	has)
		case "${2:-}" in
			authkey|adguard_password) exit 0 ;;
		esac
		;;
	matches-adguard)
		[ "${2:-}" = 'http://saved.example:3000' ] && [ "${3:-}" = 'saved-user' ]
		;;
	set-authkey|set-adguard)
		cat >"${SECRETS_STDIN_LOG:?}"
		;;
	migrate) ;;
	*) exit 1 ;;
esac
SH
chmod +x "$TMP_DIR/secrets"

cat >"$TMP_DIR/preflight" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"${PREFLIGHT_ARGV_LOG:?}"
{
	printf 'candidate=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_CANDIDATE:-}"
	printf 'api_url=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_API_URL:-}"
	printf 'username=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_USERNAME:-}"
	printf 'password_set=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_PASSWORD_SET:-}"
	printf 'password=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_PASSWORD:-}"
	printf 'default_upstreams=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_DEFAULT_UPSTREAMS:-}"
	printf 'tailnet_upstreams=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_TAILNET_UPSTREAMS:-}"
	printf 'health_domain=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_HEALTH_DOMAIN:-}"
	printf 'expected_ips=%s\n' "${TAILSCALE_ADGUARD_PREFLIGHT_EXPECTED_IPS:-}"
} >"${PREFLIGHT_ENV_LOG:?}"
printf 'adguard_process=pass\nhealth_check=pass\nready=pass\n'
SH
chmod +x "$TMP_DIR/preflight"

PREFLIGHT_ARGV_LOG="$TMP_DIR/argv.log"
PREFLIGHT_ENV_LOG="$TMP_DIR/env.log"
SECRETS_ARGV_LOG="$TMP_DIR/secrets-argv.log"
SECRETS_STDIN_LOG="$TMP_DIR/secrets-stdin.log"
export PREFLIGHT_ARGV_LOG PREFLIGHT_ENV_LOG SECRETS_ARGV_LOG SECRETS_STDIN_LOG
: >"$SECRETS_ARGV_LOG"
: >"$SECRETS_STDIN_LOG"

list_json="$(PRECHECK_BIN="$TMP_DIR/preflight" SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" list)"
printf '%s' "$list_json" | jq -e '.adguard_preflight.candidate == "" and .adguard_preflight.password == ""' >/dev/null || \
	fail "rpcd list output must declare the AdGuard preflight string arguments"
printf '%s' "$list_json" | jq -e '.secret_status == {} and .set_secret.name == "" and .set_secret.value == ""' >/dev/null || \
	fail "rpcd list output must declare secret status and write methods"

status_response="$(printf '%s\n' '{}' | SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" call secret_status)"
printf '%s' "$status_response" | jq -e '.authkey_set == "1" and .adguard_password_set == "1"' >/dev/null || \
	fail "secret status must expose booleans without returning secret values"
grep -Fx 'migrate' "$SECRETS_ARGV_LOG" >/dev/null || fail "secret status must migrate readable legacy credentials before reporting status"

request='{"candidate":"1","api_url":"http://candidate.example:3000","username":"candidate-user","password_set":"1","password":"candidate-secret","default_upstreams":"1.1.1.1\\n8.8.8.8","tailnet_upstreams":"[/candidate.example/]100.100.100.100","health_domain":"candidate-health.example","expected_ips":"10.23.0.15\\n10.23.0.16"}'
response="$(printf '%s\n' "$request" | PRECHECK_BIN="$TMP_DIR/preflight" SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" call adguard_preflight)"

printf '%s' "$response" | jq -e '.ready == "pass" and .health_check == "pass" and .code == 0' >/dev/null || \
	fail "rpcd preflight must return the structured checker result"
[ "$(cat "$PREFLIGHT_ARGV_LOG")" = "--preflight" ] || fail "candidate values and credentials must not enter the checker argv"
grep -F 'candidate=1' "$PREFLIGHT_ENV_LOG" >/dev/null || fail "rpcd preflight must enable candidate mode"
grep -F 'api_url=http://candidate.example:3000' "$PREFLIGHT_ENV_LOG" >/dev/null || fail "rpcd preflight must pass the candidate API URL"
grep -F 'password=candidate-secret' "$PREFLIGHT_ENV_LOG" >/dev/null || fail "rpcd preflight must pass the candidate password through the child environment"
grep -F 'default_upstreams=1.1.1.1' "$PREFLIGHT_ENV_LOG" >/dev/null || fail "rpcd preflight must preserve candidate upstreams"

: >"$PREFLIGHT_ARGV_LOG"
reuse_request='{"candidate":"1","api_url":"http://attacker.example:3000","username":"saved-user","password_set":"0","password":"","default_upstreams":"1.1.1.1","tailnet_upstreams":"[/candidate.example/]100.100.100.100","health_domain":"candidate-health.example","expected_ips":"10.23.0.15"}'
if printf '%s\n' "$reuse_request" | PRECHECK_BIN="$TMP_DIR/preflight" SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" call adguard_preflight >/dev/null 2>&1; then
	fail "preflight must reject saved-password reuse for a different AdGuard endpoint"
fi
[ ! -s "$PREFLIGHT_ARGV_LOG" ] || fail "rejected credential reuse must not invoke the preflight checker"

: >"$PREFLIGHT_ARGV_LOG"
unsafe_request='{"candidate":"1","api_url":"file:///etc/shadow","username":"candidate-user","password_set":"1","password":"candidate-secret","default_upstreams":"1.1.1.1","tailnet_upstreams":"[/candidate.example/]100.100.100.100","health_domain":"candidate-health.example","expected_ips":"10.23.0.15"}'
if printf '%s\n' "$unsafe_request" | PRECHECK_BIN="$TMP_DIR/preflight" SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" call adguard_preflight >/dev/null 2>&1; then
	fail "preflight must reject non-HTTP AdGuard API URLs"
fi
[ ! -s "$PREFLIGHT_ARGV_LOG" ] || fail "rejected API schemes must not invoke the preflight checker"

set_request='{"name":"adguard_password","value":"new-secret","api_url":"http://new.example:3000","username":"new-user"}'
printf '%s\n' "$set_request" | SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" call set_secret >/dev/null
printf '%s' "$(cat "$SECRETS_STDIN_LOG")" | jq -e '.password == "new-secret" and .api_url == "http://new.example:3000" and .username == "new-user"' >/dev/null || \
	fail "AdGuard secret writes must preserve the endpoint binding"

printf '%s\n' '{}' | PRECHECK_BIN="$TMP_DIR/preflight" SECRETS_BIN="$TMP_DIR/secrets" "$RPCD_SCRIPT" call unknown >/dev/null 2>&1 && \
	fail "unknown rpcd methods must fail closed"

echo "tailscale rpcd tests passed"
