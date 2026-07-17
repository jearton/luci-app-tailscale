#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_openclash_bypass"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-openclash-test.$$"
REAL_CHOWN="$(command -v chown)"
REAL_DD="$(command -v dd)"
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
cat >"$TMP_DIR/bin/dd" <<'SH'
#!/bin/sh
has_count=0
has_skip=0
for arg in "$@"; do
	case "$arg" in
		count=*) has_count=1 ;;
		skip=*) has_skip=1 ;;
	esac
done
if [ "${DD_FAIL_PREFIX:-0}" = 1 ] && [ "$has_count" = 1 ] && [ "$has_skip" = 0 ]; then
	printf 'failed: %s\n' "$*" >>"${DD_LOG:?}"
	exit 1
fi
printf 'passed: %s\n' "$*" >>"${DD_LOG:?}"
exec "${REAL_DD:?}" "$@"
SH
chmod +x "$TMP_DIR/bin/dd"
cat >"$TMP_DIR/bin/uci" <<'SH'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"${UCI_LOG:?}"
case "$*" in
	'-q get tailscale_openclash.settings.enabled')
		[ -n "${FEATURE_ENABLED:-}" ] || exit 1
		printf '%s\n' "$FEATURE_ENABLED"
		;;
	*)
		printf 'unsupported fake uci command: %s\n' "$*" >&2
		exit 99
		;;
esac
SH
chmod +x "$TMP_DIR/bin/uci"
cat >"$TMP_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod +x "$TMP_DIR/bin/logger"
cat >"$TMP_DIR/bin/nft" <<'SH'
#!/bin/sh
set -eu

state="${NFT_STATE:?}"
batch_log="${NFT_BATCH_LOG:?}"
call_log="${NFT_CALL_LOG:?}"

printf '%s\n' "$*" >>"$call_log"

print_chain_json() {
	chain="$1"
	printf '{"nftables":[{"chain":{"family":"inet","table":"fw4","name":"%s"}}' "$chain"
	while IFS='|' read -r handle rule || [ -n "${handle:-}" ]; do
		case "$rule" in
			"insert rule inet fw4 $chain "*) ;;
			*) continue ;;
		esac
		comment="$(printf '%s\n' "$rule" | sed -n 's/.*comment "\(.*\)" return$/\1/p')"
		[ -n "$comment" ] || continue
		printf ',{"rule":{"family":"inet","table":"fw4","chain":"%s","comment":"%s","handle":%s}}' \
			"$chain" "$comment" "$handle"
	done <"$state"
	printf ']}\n'
}

delete_rule() {
	chain="$1"
	handle="$2"
	temp_file="$(mktemp "${state}.XXXXXX")"
	while IFS='|' read -r stored_handle stored_rule || [ -n "${stored_handle:-}" ]; do
		if [ "$stored_handle" = "$handle" ]; then
			case "$stored_rule" in
				"insert rule inet fw4 $chain "*) continue ;;
			esac
		fi
		printf '%s|%s\n' "$stored_handle" "$stored_rule" >>"$temp_file"
	done <"$state"
	mv "$temp_file" "$state"
}

apply_batch() {
	batch="$1"
	cp "$state" "${state}.next"
	while IFS= read -r statement || [ -n "$statement" ]; do
		case "$statement" in
			'delete rule inet fw4 '*)
				rest="${statement#delete rule inet fw4 }"
				chain="${rest%% handle *}"
				handle="${rest##* handle }"
				state="$state" delete_rule "$chain" "$handle"
				;;
			'insert rule inet fw4 '*)
				next_handle="$(awk -F '|' 'BEGIN { max = 0 } $1 + 0 > max { max = $1 + 0 } END { print max + 1 }' "$state")"
				printf '%s|%s\n' "$next_handle" "$statement" >>"$state"
				;;
			*)
				printf 'unsupported fake nft statement: %s\n' "$statement" >&2
				mv "${state}.next" "$state"
				exit 99
				;;
		esac
	done <"$batch"
	rm -f "${state}.next"
}

if [ "$#" = 5 ] && [ "$1" = '-j' ] && [ "$2" = 'list' ] && [ "$3" = 'table' ] && \
	[ "$4" = 'inet' ] && [ "$5" = 'fw4' ]; then
	[ "${NFT_TABLE_MISSING:-0}" = 1 ] && exit 1
	if [ "${NFT_JSON_UNSUPPORTED:-0}" = 1 ]; then
		printf 'not-json\n'
	else
		printf '{"nftables":[{"table":{"family":"inet","name":"fw4"}}]}\n'
	fi
	exit 0
fi

if [ "$#" = 7 ] && [ "$1" = '-j' ] && [ "$2" = '-a' ] && [ "$3" = 'list' ] && \
	[ "$4" = 'chain' ] && [ "$5" = 'inet' ] && [ "$6" = 'fw4' ]; then
	chain="$7"
	[ "${MISSING_CHAIN:-}" = "$chain" ] && exit 1
	if [ "${NFT_JSON_UNSUPPORTED:-0}" = 1 ]; then
		printf 'not-json\n'
	else
		print_chain_json "$chain"
	fi
	exit 0
fi

if [ "$#" = 2 ] && [ "$1" = '-f' ]; then
	cat "$2" >"$batch_log"
	[ "${NFT_BATCH_FAIL:-0}" = 1 ] && exit 1
	apply_batch "$2"
	exit 0
fi

printf 'unsupported fake nft command: %s\n' "$*" >&2
exit 99
SH
chmod +x "$TMP_DIR/bin/nft"
touch "$TMP_DIR/openclash-init"
chmod +x "$TMP_DIR/openclash-init"
HOOK="$TMP_DIR/openclash/custom/openclash_custom_firewall_rules.sh"
printf '#!/bin/sh\nprintf user-before\nprintf user-after\n' >"$HOOK"
chmod 750 "$HOOK"
original_owner="$(file_owner "$HOOK")"
original_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
FLOCK_LOG="$TMP_DIR/flock.log"
CHOWN_LOG="$TMP_DIR/chown.log"
DD_LOG="$TMP_DIR/dd.log"
NFT_STATE="$TMP_DIR/nft.state"
NFT_BATCH_LOG="$TMP_DIR/nft.batch"
NFT_CALL_LOG="$TMP_DIR/nft.calls"
UCI_LOG="$TMP_DIR/uci.log"
LOGGER_LOG="$TMP_DIR/logger.log"
: >"$NFT_STATE"
: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
: >"$UCI_LOG"
: >"$LOGGER_LOG"
export FLOCK_LOG CHOWN_LOG DD_LOG REAL_CHOWN REAL_DD NFT_STATE NFT_BATCH_LOG NFT_CALL_LOG UCI_LOG LOGGER_LOG

run_helper() {
	OPENCLASH_INIT="$TMP_DIR/openclash-init" \
	OPENCLASH_HOOK_FILE="$HOOK" \
	LOCK_FILE="$TMP_DIR/lock" \
	UCI_BIN="$TMP_DIR/bin/uci" \
	NFT_BIN="$TMP_DIR/bin/nft" \
	JQ_BIN=jq \
	LOGGER_CMD="$TMP_DIR/bin/logger" \
	DD_FAIL_PREFIX="${DD_FAIL_PREFIX:-0}" \
	FEATURE_ENABLED="${FEATURE_ENABLED:-}" \
	PATH="$TMP_DIR/bin:$PATH" \
	"$SCRIPT" "$@"
}

failed_reconcile_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
failed_reconcile_mode="$(file_mode "$HOOK")"
failed_reconcile_owner="$(file_owner "$HOOK")"
: >"$DD_LOG"
if DD_FAIL_PREFIX=1 run_helper reconcile-hook; then
	fail 'reconcile-hook must fail when prefix copy fails'
fi
DD_FAIL_PREFIX=0
grep -F 'failed:' "$DD_LOG" >/dev/null || fail 'reconcile-hook did not execute the failing prefix copy'
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$failed_reconcile_hash" ] || \
	fail 'reconcile-hook changed hook after prefix copy failure'
[ "$(file_mode "$HOOK")" = "$failed_reconcile_mode" ] || \
	fail 'reconcile-hook changed hook mode after prefix copy failure'
[ "$(file_owner "$HOOK")" = "$failed_reconcile_owner" ] || \
	fail 'reconcile-hook changed hook ownership after prefix copy failure'

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
failed_cleanup_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
failed_cleanup_mode="$(file_mode "$HOOK")"
failed_cleanup_owner="$(file_owner "$HOOK")"
: >"$DD_LOG"
if DD_FAIL_PREFIX=1 run_helper cleanup; then
	fail 'cleanup must fail when prefix copy fails'
fi
DD_FAIL_PREFIX=0
grep -F 'failed:' "$DD_LOG" >/dev/null || fail 'cleanup did not execute the failing prefix copy'
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$failed_cleanup_hash" ] || \
	fail 'cleanup changed hook after prefix copy failure'
[ "$(file_mode "$HOOK")" = "$failed_cleanup_mode" ] || \
	fail 'cleanup changed hook mode after prefix copy failure'
[ "$(file_owner "$HOOK")" = "$failed_cleanup_owner" ] || \
	fail 'cleanup changed hook ownership after prefix copy failure'

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

touch "$TMP_DIR/openclash-init"
chmod +x "$TMP_DIR/openclash-init"
: >"$NFT_STATE"
: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
: >"$UCI_LOG"

run_helper apply
assert_count 1 'insert rule inet fw4 openclash_mangle_output ' "$NFT_BATCH_LOG"
assert_count 1 'insert rule inet fw4 openclash_output ' "$NFT_BATCH_LOG"
assert_count 1 'insert rule inet fw4 openclash_mangle iifname "tailscale0"' "$NFT_BATCH_LOG"
assert_count 1 'insert rule inet fw4 openclash iifname "tailscale0"' "$NFT_BATCH_LOG"
assert_count 4 '-j -a list chain inet fw4 ' "$NFT_CALL_LOG"
assert_count 1 '-f ' "$NFT_CALL_LOG"
grep -F 'comment "luci-app-tailscale: Tailscale 标记流量绕过 OpenClash（mangle output）" return' "$NFT_BATCH_LOG" >/dev/null || \
	fail 'mangle output rule comment is not exact'
grep -F 'comment "luci-app-tailscale: Tailscale 标记流量绕过 OpenClash（output）" return' "$NFT_BATCH_LOG" >/dev/null || \
	fail 'output rule comment is not exact'
grep -F 'comment "luci-app-tailscale: tailscale0 入站流量绕过 OpenClash（mangle）" return' "$NFT_BATCH_LOG" >/dev/null || \
	fail 'mangle ingress rule comment is not exact'
grep -F 'comment "luci-app-tailscale: tailscale0 入站流量绕过 OpenClash（filter）" return' "$NFT_BATCH_LOG" >/dev/null || \
	fail 'filter ingress rule comment is not exact'

run_helper apply
[ "$(grep -c 'insert rule inet fw4' "$NFT_STATE")" = 4 ] || fail 'repeated apply duplicated owned rules'

hook_before_status="$(sha256sum "$HOOK" | awk '{print $1}')"
state_before_status="$(sha256sum "$NFT_STATE" | awk '{print $1}')"
: >"$NFT_BATCH_LOG"
printf '%s' "$(run_helper status)" | jq -e '
	.state == "active" and .enabled == true and .openclash_present == true and
	.firewall4_supported == true and .hook == "managed" and .rules_present == 4 and
	.message == "OpenClash bypass is active."
' >/dev/null || fail 'complete managed state did not report active'
[ ! -s "$NFT_BATCH_LOG" ] || fail 'status mutated nftables state'
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$hook_before_status" ] || fail 'status rewrote the hook'
[ "$(sha256sum "$NFT_STATE" | awk '{print $1}')" = "$state_before_status" ] || fail 'status rewrote nftables state'

: >"$NFT_BATCH_LOG"
MISSING_CHAIN=openclash_output run_helper apply
[ ! -s "$NFT_BATCH_LOG" ] || fail 'missing target chain produced a partial nft transaction'
printf '%s' "$(MISSING_CHAIN=openclash_output run_helper status)" | jq -e '.state == "waiting"' >/dev/null || \
	fail 'missing chain did not report waiting'
MISSING_CHAIN=

: >"$NFT_BATCH_LOG"
state_before_failed_batch="$(sha256sum "$NFT_STATE" | awk '{print $1}')"
if NFT_BATCH_FAIL=1 run_helper apply; then
	fail 'apply must fail when the nft batch fails'
fi
NFT_BATCH_FAIL=0
[ -s "$NFT_BATCH_LOG" ] || fail 'failed apply did not submit an nft batch'
[ "$(sha256sum "$NFT_STATE" | awk '{print $1}')" = "$state_before_failed_batch" ] || \
	fail 'failed nft batch changed state'
grep -F 'OpenClash nftables reconciliation transaction failed.' "$LOGGER_LOG" >/dev/null || \
	fail 'failed nft batch was not logged'

FEATURE_ENABLED=0 run_helper apply
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null && fail 'disabled apply left owned nft rules'
printf '%s' "$(FEATURE_ENABLED=0 run_helper status)" | jq -e '.state == "disabled" and .enabled == false' >/dev/null || \
	fail 'disabled setting did not take status precedence'
FEATURE_ENABLED=

run_helper apply
if NFT_BATCH_FAIL=1 run_helper cleanup; then
	fail 'cleanup must fail when the nft delete batch fails'
fi
NFT_BATCH_FAIL=0
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null || fail 'failed cleanup batch changed owned nft rules'
grep -F 'luci-app-tailscale 托管' "$HOOK" >/dev/null && fail 'cleanup did not run hook cleanup before the nft batch'
run_helper reconcile-hook
printf '%s\n' '900|insert rule inet fw4 openclash iifname "tailscale0" counter comment "user-owned-rule" return' >>"$NFT_STATE"
run_helper cleanup
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null && fail 'cleanup left owned nft rules'
grep -F 'user-owned-rule' "$NFT_STATE" >/dev/null || fail 'cleanup removed a user-owned rule'
grep -F 'luci-app-tailscale 托管' "$HOOK" >/dev/null && fail 'cleanup left the managed hook block'
printf '%s' "$(run_helper status)" | jq -e '.state == "error"' >/dev/null || \
	fail 'incomplete managed state did not report error'

printf '%s\n' '# BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash' >>"$HOOK"
printf '%s' "$(run_helper status)" | jq -e '.state == "error"' >/dev/null || \
	fail 'malformed markers did not report error'
printf '%s' "$(NFT_TABLE_MISSING=1 FEATURE_ENABLED=0 run_helper status)" | jq -e '.state == "unsupported"' >/dev/null || \
	fail 'unsupported firewall4 state did not take precedence over disabled and malformed states'
printf '%s' "$(NFT_JSON_UNSUPPORTED=1 FEATURE_ENABLED=0 run_helper status)" | jq -e '.state == "unsupported"' >/dev/null || \
	fail 'unsupported nft JSON did not report unsupported'
rm -f "$TMP_DIR/openclash-init"
printf '%s' "$(NFT_TABLE_MISSING=1 run_helper status)" | jq -e '.state == "absent"' >/dev/null || \
	fail 'OpenClash absence did not take status precedence'
grep -F 'firewall' "$UCI_LOG" >/dev/null && fail 'helper queried the firewall UCI package'

printf '%s\n' 'tailscale OpenClash bypass tests passed'
