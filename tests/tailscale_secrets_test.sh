#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_secrets"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-secrets-test.$$"
SECRET_FILE="$TMP_DIR/luci-secrets.json"
UCI_LOG="$TMP_DIR/uci.log"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
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

file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

mkdir -p "$TMP_DIR"
: >"$UCI_LOG"
export UCI_LOG

cat >"$TMP_DIR/uci" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${UCI_LOG:?}"
case "$*" in
	"-q get tailscale.settings.authkey") printf '%s\n' "${LEGACY_AUTHKEY:-}" ;;
	"-q get tailscale.settings.adguard_password") printf '%s\n' "${LEGACY_ADGUARD_PASSWORD:-}" ;;
	"-q get tailscale.settings.adguard_api_url") printf '%s\n' "${LEGACY_ADGUARD_API_URL:-http://127.0.0.1:3000}" ;;
	"-q get tailscale.settings.adguard_username") printf '%s\n' "${LEGACY_ADGUARD_USERNAME:-}" ;;
	"-q delete tailscale.settings.authkey"|"-q delete tailscale.settings.adguard_password"|"commit tailscale") ;;
	*) exit 1 ;;
esac
SH
chmod +x "$TMP_DIR/uci"

run_secrets() {
	TAILSCALE_SECRETS_FILE="$SECRET_FILE" \
	UCI_CMD="$TMP_DIR/uci" \
	JQ_CMD="$(command -v jq)" \
	"$SCRIPT" "$@"
}

authkey='tskey-auth-special-$HOME-$(not-expanded)-"quoted"-\backslash'
printf '%s' "$authkey" | run_secrets set-authkey
assert_eq "$authkey" "$(run_secrets get authkey)" "auth key must round-trip without shell expansion"
assert_eq 600 "$(file_mode "$SECRET_FILE")" "secret file must be root-only"
if find "$TMP_DIR" -maxdepth 1 -type f -name '.luci-secrets-*' | grep -q .; then
	fail "secret updates must not leave temporary credential files behind"
fi

adguard_password='adguard-password-$HOME-$(not-expanded)-"quoted"-\backslash'
jq -nc \
	--arg password "$adguard_password" \
	--arg api_url 'http://127.0.0.1:3000/' \
	--arg username 'root' \
	'{password:$password,api_url:$api_url,username:$username}' | run_secrets set-adguard

run_secrets matches-adguard 'http://127.0.0.1:3000' root || fail "saved AdGuard binding must match its normalized endpoint"
assert_eq "$adguard_password" "$(run_secrets adguard-password-for 'http://127.0.0.1:3000/' root)" "matching AdGuard endpoint must receive the saved password"
if find "$TMP_DIR" -maxdepth 1 -type f -name '.luci-secrets-*' | grep -q .; then
	fail "AdGuard secret updates must clean temporary credential files"
fi
if run_secrets matches-adguard 'http://attacker.example:3000' root; then
	fail "changed AdGuard endpoint must not match the saved credential binding"
fi
if run_secrets adguard-password-for 'http://attacker.example:3000' root >"$TMP_DIR/mismatch.out"; then
	fail "changed AdGuard endpoint must not receive the saved password"
fi
[ ! -s "$TMP_DIR/mismatch.out" ] || fail "mismatched AdGuard endpoint leaked the saved password"

if jq -nc '{password:"secret",api_url:"file:///etc/shadow",username:"root"}' | run_secrets set-adguard >/dev/null 2>&1; then
	fail "AdGuard credentials must only bind to HTTP or HTTPS API URLs"
fi

rm -f "$SECRET_FILE"
export LEGACY_AUTHKEY='legacy-auth-key'
export LEGACY_ADGUARD_PASSWORD='legacy-adguard-password'
export LEGACY_ADGUARD_API_URL='http://legacy.example:3000/'
export LEGACY_ADGUARD_USERNAME='legacy-user'
run_secrets migrate

assert_eq 'legacy-auth-key' "$(run_secrets get authkey)" "migration must preserve the legacy auth key"
assert_eq 'legacy-adguard-password' "$(run_secrets adguard-password-for 'http://legacy.example:3000' legacy-user)" "migration must bind and preserve the legacy AdGuard password"
grep -F -- '-q delete tailscale.settings.authkey' "$UCI_LOG" >/dev/null || fail "migration must delete the readable legacy auth key"
grep -F -- '-q delete tailscale.settings.adguard_password' "$UCI_LOG" >/dev/null || fail "migration must delete the readable legacy AdGuard password"
grep -F -- 'commit tailscale' "$UCI_LOG" >/dev/null || fail "migration must commit removal of legacy credentials"

printf '%s\n' 'tailscale secret storage tests passed'
