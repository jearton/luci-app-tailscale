#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_openclash_bypass"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-openclash-test.$$"
REAL_CHOWN="$(command -v chown)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
file_owner() {
	stat -c '%u:%g' "$1" 2>/dev/null || stat -f '%u:%g' "$1"
}
assert_count() {
	expected="$1"; needle="$2"; file="$3"
	actual="$(grep -cF -- "$needle" "$file" || true)"
	[ "$actual" = "$expected" ] || fail "$file expected $expected occurrences of $needle, got $actual"
}
assert_chown_owner() {
	owner="$1"
	grep -F -- "$owner " "$CHOWN_LOG" >/dev/null || fail "chown did not receive numeric owner/group $owner"
}

mkdir -p "$TMP_DIR/openclash/custom" "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/flock" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FLOCK_LOG:?}"
[ "$*" = '-x 9' ]
SH
chmod +x "$TMP_DIR/bin/flock"
cat >"$TMP_DIR/bin/chown" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${CHOWN_LOG:?}"
exec "${REAL_CHOWN:?}" "$@"
SH
chmod +x "$TMP_DIR/bin/chown"
touch "$TMP_DIR/openclash-init"
chmod +x "$TMP_DIR/openclash-init"
HOOK="$TMP_DIR/openclash/custom/openclash_custom_firewall_rules.sh"
printf '#!/bin/sh\nprintf user-before\nprintf user-after\n' >"$HOOK"
chmod 750 "$HOOK"
original_owner="$(file_owner "$HOOK")"
original_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
FLOCK_LOG="$TMP_DIR/flock.log"
CHOWN_LOG="$TMP_DIR/chown.log"
export FLOCK_LOG CHOWN_LOG REAL_CHOWN

run_helper() {
	OPENCLASH_INIT="$TMP_DIR/openclash-init" \
	OPENCLASH_HOOK_FILE="$HOOK" \
	LOCK_FILE="$TMP_DIR/lock" \
	UCI_BIN="$TMP_DIR/bin/uci" \
	NFT_BIN="$TMP_DIR/bin/nft" \
	JQ_BIN=jq \
	PATH="$TMP_DIR/bin:$PATH" \
	"$SCRIPT" "$@"
}

run_helper reconcile-hook
assert_count 1 '# BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash' "$HOOK"
assert_count 1 '# END luci-app-tailscale 托管：Tailscale 绕过 OpenClash' "$HOOK"
grep -F 'printf user-before' "$HOOK" >/dev/null || fail 'hook insertion removed user content before the block'
grep -F 'printf user-after' "$HOOK" >/dev/null || fail 'hook insertion removed user content after the block'
[ "$(file_mode "$HOOK")" = 750 ] || fail 'hook mode changed'
[ "$(file_owner "$HOOK")" = "$original_owner" ] || fail 'hook ownership changed'

first_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
run_helper reconcile-hook
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$first_hash" ] || fail 'reconcile-hook is not idempotent'

cp "$HOOK" "$TMP_DIR/hook-before-malformed"
printf '%s\n' '# BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash' >>"$HOOK"
malformed_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
if run_helper reconcile-hook >/dev/null 2>&1; then
	fail 'duplicate managed markers must fail'
fi
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$malformed_hash" ] || fail 'malformed hook changed after rejection'

cp "$TMP_DIR/hook-before-malformed" "$HOOK"
: >"$FLOCK_LOG"
: >"$CHOWN_LOG"
run_helper cleanup
assert_count 1 '-x 9' "$FLOCK_LOG"
assert_chown_owner "$original_owner"
grep -F 'luci-app-tailscale 托管' "$HOOK" >/dev/null && fail 'cleanup left the managed hook block'
grep -F 'printf user-before' "$HOOK" >/dev/null || fail 'cleanup removed user content'
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$original_hash" ] || \
	fail 'hook cleanup did not restore every original byte'
[ "$(file_mode "$HOOK")" = 750 ] || fail 'cleanup changed hook mode'
[ "$(file_owner "$HOOK")" = "$original_owner" ] || fail 'cleanup changed hook ownership'

printf '#!/bin/sh\nprintf user-without-trailing-newline' >"$HOOK"
chmod 740 "$HOOK"
no_newline_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
run_helper reconcile-hook
run_helper cleanup
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$no_newline_hash" ] || \
	fail 'cleanup did not restore a hook without a trailing newline'

rm -f "$TMP_DIR/openclash-init" "$HOOK"
run_helper reconcile-hook
[ ! -e "$HOOK" ] || fail 'OpenClash-absent reconciliation created a custom script'

touch "$TMP_DIR/openclash-init"
chmod +x "$TMP_DIR/openclash-init"
run_helper reconcile-hook
[ -x "$HOOK" ] || fail 'missing OpenClash custom script was not created executable'
sh -n "$HOOK" || fail 'created hook is not valid shell'

absent_cleanup_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
absent_cleanup_mode="$(file_mode "$HOOK")"
absent_cleanup_owner="$(file_owner "$HOOK")"
rm -f "$TMP_DIR/openclash-init"
: >"$FLOCK_LOG"
: >"$CHOWN_LOG"
run_helper cleanup
assert_count 1 '-x 9' "$FLOCK_LOG"
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$absent_cleanup_hash" ] || \
	fail 'cleanup when OpenClash is absent rewrote the managed hook'
[ "$(file_mode "$HOOK")" = "$absent_cleanup_mode" ] || \
	fail 'cleanup when OpenClash is absent changed hook mode'
[ "$(file_owner "$HOOK")" = "$absent_cleanup_owner" ] || \
	fail 'cleanup when OpenClash is absent changed hook ownership'
[ ! -s "$CHOWN_LOG" ] || fail 'cleanup when OpenClash is absent invoked chown'

printf '%s\n' 'tailscale OpenClash hook reconciliation tests passed'
