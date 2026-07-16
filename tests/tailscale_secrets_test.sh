#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_secrets"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-secrets-test.$$"
SECRET_FILE="$TMP_DIR/luci-secrets.json"
UCI_LOG="$TMP_DIR/uci.log"
UCI_REF_FILE="$TMP_DIR/uci-secrets-ref"

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
export UCI_LOG UCI_REF_FILE

cat >"$TMP_DIR/uci" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${UCI_LOG:?}"
case "$*" in
	"-q get tailscale.settings.authkey") printf '%s\n' "${LEGACY_AUTHKEY:-}" ;;
	"-q get tailscale.settings.adguard_password") printf '%s\n' "${LEGACY_ADGUARD_PASSWORD:-}" ;;
	"-q get tailscale.settings.adguard_api_url") printf '%s\n' "${LEGACY_ADGUARD_API_URL:-http://127.0.0.1:3000}" ;;
	"-q get tailscale.settings.adguard_username") printf '%s\n' "${LEGACY_ADGUARD_USERNAME:-}" ;;
	"-q get tailscale.settings.secrets_ref") [ -f "$UCI_REF_FILE" ] && cat "$UCI_REF_FILE" ;;
	"-q set tailscale.settings.secrets_ref="*) printf '%s\n' "${3#*=}" >"$UCI_REF_FILE" ;;
	"-q delete tailscale.settings.authkey"|"-q delete tailscale.settings.adguard_password"|"commit tailscale") ;;
	*) exit 1 ;;
esac
SH
chmod +x "$TMP_DIR/uci"

if command -v flock >/dev/null 2>&1; then
	FLOCK_CMD="$(command -v flock)"
else
	cat >"$TMP_DIR/flock" <<'SH'
#!/bin/sh
exit 0
SH
	chmod +x "$TMP_DIR/flock"
	FLOCK_CMD="$TMP_DIR/flock"
fi

run_secrets() {
	TAILSCALE_SECRETS_FILE="$SECRET_FILE" \
	UCI_CMD="$TMP_DIR/uci" \
	JQ_CMD="$(command -v jq)" \
	FLOCK_BIN="$FLOCK_CMD" \
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

batch_authkey='batch-auth-key'
batch_password='batch-adguard-password'
jq -nc \
	--arg authkey "$batch_authkey" \
	--arg password "$batch_password" \
	'{authkey:$authkey,adguard:{password:$password,api_url:"https://adguard.example:3000/",username:"batch-user"}}' |
	run_secrets set-batch
assert_eq "$batch_authkey" "$(run_secrets get authkey)" "batch updates must atomically preserve the auth key"
assert_eq "$batch_password" "$(run_secrets adguard-password-for 'https://adguard.example:3000' batch-user)" "batch updates must atomically preserve the bound AdGuard password"
[ -f "$TMP_DIR/.luci-secrets.lock" ] || fail "secret access must use a persistent lock file"
assert_eq 600 "$(file_mode "$TMP_DIR/.luci-secrets.lock")" "secret lock file must be root-only"
jq -e '.schema == 2 and (.active_ref | type == "string") and (.versions[.active_ref] | type == "object")' "$SECRET_FILE" >/dev/null || \
	fail "secret storage must use a versioned schema with an explicit active reference"

active_ref="$(run_secrets active-ref)"
staged_auth_ref="$(printf '%s' 'staged-auth-key' | run_secrets stage-authkey "$active_ref")"
assert_eq "$batch_authkey" "$(run_secrets get authkey)" "staging a credential version must not change the active auth key"
staged_combined_ref="$(
	jq -nc '{authkey:null,adguard:{password:"staged-adguard-password",api_url:"https://staged.example:3000",username:"staged-user"}}' |
		run_secrets stage-batch "$staged_auth_ref"
)"
run_secrets activate "$staged_combined_ref"
assert_eq 'staged-auth-key' "$(run_secrets get authkey)" "a second staged update must inherit the first staged version"
assert_eq 'staged-adguard-password' "$(run_secrets adguard-password-for 'https://staged.example:3000' staged-user)" "activating a staged version must expose its bound AdGuard password"
run_secrets activate "$active_ref"
assert_eq "$batch_authkey" "$(run_secrets get authkey)" "reactivating the previous UCI reference must roll credentials back"

printf '%s\n' '{"authkey":"flat-file-auth"}' >"$SECRET_FILE"
rm -f "$UCI_REF_FILE"
unset LEGACY_AUTHKEY LEGACY_ADGUARD_PASSWORD LEGACY_ADGUARD_API_URL LEGACY_ADGUARD_USERNAME || true
run_secrets migrate
assert_eq 'flat-file-auth' "$(run_secrets get authkey)" "migration must preserve the pre-versioned secret file"
jq -e '.schema == 2 and (.versions[.active_ref].authkey == "flat-file-auth")' "$SECRET_FILE" >/dev/null || \
	fail "migration must wrap the old flat secret object in a version"

rm -f "$SECRET_FILE"
rm -f "$UCI_REF_FILE"
export LEGACY_AUTHKEY='legacy-auth-key'
export LEGACY_ADGUARD_PASSWORD='legacy-adguard-password'
export LEGACY_ADGUARD_API_URL='http://legacy.example:3000/'
export LEGACY_ADGUARD_USERNAME='legacy-user'
run_secrets migrate

assert_eq 'legacy-auth-key' "$(run_secrets get authkey)" "migration must preserve the legacy auth key"
assert_eq 'legacy-adguard-password' "$(run_secrets adguard-password-for 'http://legacy.example:3000' legacy-user)" "migration must bind and preserve the legacy AdGuard password"
grep -F -- '-q delete tailscale.settings.authkey' "$UCI_LOG" >/dev/null || fail "migration must delete the readable legacy auth key"
grep -F -- '-q delete tailscale.settings.adguard_password' "$UCI_LOG" >/dev/null || fail "migration must delete the readable legacy AdGuard password"
grep -F -- '-q set tailscale.settings.secrets_ref=' "$UCI_LOG" >/dev/null || fail "migration must persist the active secret version reference"
grep -F -- 'commit tailscale' "$UCI_LOG" >/dev/null || fail "migration must commit removal of legacy credentials"

printf '%s\n' 'tailscale secret storage tests passed'
