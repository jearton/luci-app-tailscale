#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_openclash_bypass"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-openclash-test.$$"
REAL_CHOWN="$(command -v chown)"
REAL_CHMOD="$(command -v chmod)"
REAL_DD="$(command -v dd)"
REAL_GREP="$(command -v grep)"
SYNC_ENABLE_PID=
SYNC_DISABLE_PID=

cleanup() {
	[ -z "$SYNC_ENABLE_PID" ] || kill "$SYNC_ENABLE_PID" >/dev/null 2>&1 || true
	[ -z "$SYNC_DISABLE_PID" ] || kill "$SYNC_DISABLE_PID" >/dev/null 2>&1 || true
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

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
assert_line_count() {
	expected="$1"; line="$2"; file="$3"
	actual="$(grep -Fxc -- "$line" "$file" || true)"
	[ "$actual" = "$expected" ] || fail "$file expected $expected exact occurrences of $line, got $actual"
}
assert_chown_owner() {
	owner="$1"
	grep -F -- "$owner " "$CHOWN_LOG" >/dev/null || fail "chown did not receive numeric owner/group $owner"
}
managed_hook_present() {
	grep -Fx '# BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash' "$1" >/dev/null 2>&1
}
assert_owner_before_mode() {
	owner_line="$(grep -n '^chown ' "$REPLACEMENT_LOG" | tail -n 1 | cut -d: -f1)"
	mode_line="$(grep -n '^chmod ' "$REPLACEMENT_LOG" | tail -n 1 | cut -d: -f1)"
	[ -n "$owner_line" ] || fail 'replacement did not restore hook ownership'
	[ -n "$mode_line" ] || fail 'replacement did not restore hook mode'
	[ "$owner_line" -lt "$mode_line" ] || fail 'replacement must restore owner before mode'
}

if grep -E 'grep[[:space:]]+-[^[:space:]]*b' "$SCRIPT" >/dev/null; then
	fail 'OpenClash helper must not use grep -b on BusyBox 1.36'
fi

mkdir -p "$TMP_DIR/openclash/custom" "$TMP_DIR/bin" "$TMP_DIR/tmp"
cat >"$TMP_DIR/bin/flock" <<'PL'
#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(LOCK_EX);

@ARGV == 2 && $ARGV[0] eq '-x' && $ARGV[1] =~ /^\d+$/ or die "unsupported flock arguments\n";
open my $lock_fh, "<&=$ARGV[1]" or die "cannot inherit lock fd: $!\n";
flock($lock_fh, LOCK_EX) or die "cannot acquire lock: $!\n";
PL
chmod +x "$TMP_DIR/bin/flock"
cat >"$TMP_DIR/bin/grep" <<'SH'
#!/bin/sh
for arg in "$@"; do
	case "$arg" in
		--byte-offset|-*b*)
			printf 'fake grep rejects byte offsets: %s\n' "$arg" >&2
			exit 64
			;;
	esac
done
exec "${REAL_GREP:?}" "$@"
SH
chmod +x "$TMP_DIR/bin/grep"
cat >"$TMP_DIR/bin/chown" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${CHOWN_LOG:?}"
printf 'chown %s\n' "$*" >>"${REPLACEMENT_LOG:?}"
exec "${REAL_CHOWN:?}" "$@"
SH
chmod +x "$TMP_DIR/bin/chown"
cat >"$TMP_DIR/bin/chmod" <<'SH'
#!/bin/sh
printf 'chmod %s\n' "$*" >>"${REPLACEMENT_LOG:?}"
exec "${REAL_CHMOD:?}" "$@"
SH
chmod +x "$TMP_DIR/bin/chmod"
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
if [ "${DD_SIGNAL_PARENT:-0}" = 1 ] && [ "$has_count" = 1 ] && [ "$has_skip" = 0 ]; then
	printf 'signalled: %s\n' "$*" >>"${DD_LOG:?}"
	kill -TERM "$PPID"
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
		printf 'value:%s\n' "${FEATURE_ENABLED:-default}" >>"${UCI_LOG:?}"
		if [ -n "${UCI_READY_FILE:-}" ]; then
			: >"$UCI_READY_FILE"
			while [ ! -e "${UCI_RELEASE_FILE:?}" ]; do sleep 0.05; done
		fi
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

target_chain() {
	case "$1" in
		openclash_mangle_output|openclash_output|openclash_mangle|openclash) return 0 ;;
		*) return 1 ;;
	esac
}

delete_rule_from_state() {
	state_file="$1"
	chain="$2"
	handle="$3"
	temp_file="$(mktemp "${state_file}.XXXXXX")"
	found=0
	while IFS='|' read -r stored_handle stored_rule || [ -n "${stored_handle:-}" ]; do
		if [ "$stored_handle" = "$handle" ]; then
			case "$stored_rule" in
				"insert rule inet fw4 $chain "*) found=1; continue ;;
			esac
		fi
		printf '%s|%s\n' "$stored_handle" "$stored_rule" >>"$temp_file"
	done <"$state_file"
	if [ "$found" -ne 1 ]; then
		printf 'nonexistent nft handle: %s/%s\n' "$chain" "$handle" >&2
		rm -f "$temp_file"
		return 1
	fi
	mv "$temp_file" "$state_file"
}

apply_batch() {
	batch="$1"
	next_state="$(mktemp "${state}.next.XXXXXX")"
	cp "$state" "$next_state"
	operation=0
	while IFS= read -r statement || [ -n "$statement" ]; do
		operation=$((operation + 1))
		case "$statement" in
			'delete rule inet fw4 '*)
				rest="${statement#delete rule inet fw4 }"
				chain="${rest%% handle *}"
				handle="${rest##* handle }"
				if ! delete_rule_from_state "$next_state" "$chain" "$handle"; then
					rm -f "$next_state"
					return 1
				fi
				;;
			'insert rule inet fw4 '*)
				next_handle="$(awk -F '|' 'BEGIN { max = 0 } $1 + 0 > max { max = $1 + 0 } END { print max + 1 }' "$next_state")"
				printf '%s|%s\n' "$next_handle" "$statement" >>"$next_state"
				;;
			*)
				printf 'unsupported fake nft statement: %s\n' "$statement" >&2
				rm -f "$next_state"
				exit 99
				;;
		esac
		if [ "${NFT_BATCH_FAIL_AFTER:-0}" = "$operation" ]; then
			rm -f "$next_state"
			exit 1
		fi
	done <"$batch"
	mv "$next_state" "$state"
}

print_table_json() {
	printf '{"nftables":[{"table":{"family":"inet","name":"fw4"}}'
	for chain in openclash_mangle_output openclash_output openclash_mangle openclash; do
		[ "${MISSING_CHAIN:-}" = "$chain" ] && continue
		if [ -s "${NFT_DISAPPEARED_FILE:?}" ] && grep -Fx "$chain" "$NFT_DISAPPEARED_FILE" >/dev/null; then
			continue
		fi
		printf ',{"chain":{"family":"inet","table":"fw4","name":"%s"}}' "$chain"
	done
	printf ']}\n'
}

if [ "$#" = 5 ] && [ "$1" = '-j' ] && [ "$2" = 'list' ] && [ "$3" = 'table' ] && \
	[ "$4" = 'inet' ] && [ "$5" = 'fw4' ]; then
	[ "${NFT_TABLE_MISSING:-0}" = 1 ] && exit 1
	if [ "${NFT_JSON_UNSUPPORTED:-0}" = 1 ]; then
		printf 'not-json\n'
	else
		print_table_json
	fi
	exit 0
fi

if [ "$#" = 7 ] && [ "$1" = '-j' ] && [ "$2" = '-a' ] && [ "$3" = 'list' ] && \
	[ "$4" = 'chain' ] && [ "$5" = 'inet' ] && [ "$6" = 'fw4' ]; then
	chain="$7"
	target_chain "$chain" || {
		printf 'unsupported fake nft chain: %s\n' "$chain" >&2
		exit 99
	}
	[ "${MISSING_CHAIN:-}" = "$chain" ] && exit 1
	if [ "${DISAPPEAR_CHAIN:-}" = "$chain" ] && ! grep -Fx "$chain" "${NFT_DISAPPEARED_FILE:?}" >/dev/null 2>&1; then
		printf '%s\n' "$chain" >"$NFT_DISAPPEARED_FILE"
		exit 1
	fi
	grep -Fx "$chain" "${NFT_DISAPPEARED_FILE:?}" >/dev/null 2>&1 && exit 1
	[ "${LIST_CHAIN_FAIL:-}" = "$chain" ] && exit 1
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
	if [ "${NFT_SIGNAL_PARENT:-0}" = 1 ]; then
		kill -TERM "$PPID"
		exit 1
	fi
	if [ "${NFT_GENERATION_RACE:-0}" = 1 ]; then
		first_delete="$(sed -n '1p' "$2")"
		case "$first_delete" in
			'delete rule inet fw4 '*)
				rest="${first_delete#delete rule inet fw4 }"
				chain="${rest%% handle *}"
				handle="${rest##* handle }"
				delete_rule_from_state "$state" "$chain" "$handle"
				;;
		esac
	fi
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
cat >"$HOOK" <<'EOF'
#!/bin/sh
printf user-before
printf '%s\n' 'user text mentions # BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash without owning it'
printf user-after
EOF
chmod 750 "$HOOK"
original_owner="$(file_owner "$HOOK")"
original_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
CHOWN_LOG="$TMP_DIR/chown.log"
REPLACEMENT_LOG="$TMP_DIR/replacement.log"
DD_LOG="$TMP_DIR/dd.log"
NFT_STATE="$TMP_DIR/nft.state"
NFT_BATCH_LOG="$TMP_DIR/nft.batch"
NFT_CALL_LOG="$TMP_DIR/nft.calls"
NFT_DISAPPEARED_FILE="$TMP_DIR/nft.disappeared"
UCI_LOG="$TMP_DIR/uci.log"
LOGGER_LOG="$TMP_DIR/logger.log"
: >"$NFT_STATE"
: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
: >"$NFT_DISAPPEARED_FILE"
: >"$UCI_LOG"
: >"$LOGGER_LOG"
export CHOWN_LOG REPLACEMENT_LOG DD_LOG REAL_CHOWN REAL_CHMOD REAL_DD REAL_GREP
export NFT_STATE NFT_BATCH_LOG NFT_CALL_LOG NFT_DISAPPEARED_FILE UCI_LOG LOGGER_LOG

run_helper() {
	OPENCLASH_INIT="$TMP_DIR/openclash-init" \
	OPENCLASH_HOOK_FILE="$HOOK" \
	LOCK_FILE="$TMP_DIR/lock" \
	UCI_BIN="$TMP_DIR/bin/uci" \
	NFT_BIN="$TMP_DIR/bin/nft" \
	JQ_BIN=jq \
	LOGGER_CMD="$TMP_DIR/bin/logger" \
	TMPDIR="$TMP_DIR/tmp" \
	DD_FAIL_PREFIX="${DD_FAIL_PREFIX:-0}" \
	DD_SIGNAL_PARENT="${DD_SIGNAL_PARENT:-0}" \
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
assert_line_count 1 '# BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash' "$HOOK"
assert_line_count 1 '# END luci-app-tailscale 托管：Tailscale 绕过 OpenClash' "$HOOK"
grep -F 'printf user-before' "$HOOK" >/dev/null || fail 'hook insertion removed user content before the block'
grep -F 'printf user-after' "$HOOK" >/dev/null || fail 'hook insertion removed user content after the block'
[ "$(file_mode "$HOOK")" = 750 ] || fail 'hook mode changed'
[ "$(file_owner "$HOOK")" = "$original_owner" ] || fail 'hook ownership changed'

first_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
run_helper reconcile-hook
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$first_hash" ] || fail 'reconcile-hook is not idempotent'

sed 's#^[[:space:]]*/usr/sbin/tailscale_openclash_bypass apply$#\tprintf stale-managed-body#' "$HOOK" >"$TMP_DIR/stale-hook"
chmod 750 "$TMP_DIR/stale-hook"
mv "$TMP_DIR/stale-hook" "$HOOK"
run_helper reconcile-hook
grep -Fx '	/usr/sbin/tailscale_openclash_bypass apply' "$HOOK" >/dev/null || \
	fail 'reconcile-hook did not restore the canonical managed command'
grep -F 'stale-managed-body' "$HOOK" >/dev/null && \
	fail 'reconcile-hook retained a stale managed body'
grep -F 'user text mentions # BEGIN luci-app-tailscale' "$HOOK" >/dev/null || \
	fail 'reconcile-hook removed marker-like user text'

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

: >"$CHOWN_LOG"
: >"$REPLACEMENT_LOG"
run_helper cleanup
assert_chown_owner "$original_owner"
assert_owner_before_mode
managed_hook_present "$HOOK" && fail 'cleanup left the managed hook block'
grep -F 'printf user-before' "$HOOK" >/dev/null || fail 'cleanup removed user content'
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$original_hash" ] || \
	fail 'hook cleanup did not restore every original byte'
[ "$(file_mode "$HOOK")" = 750 ] || fail 'cleanup changed hook mode'
[ "$(file_owner "$HOOK")" = "$original_owner" ] || fail 'cleanup changed hook ownership'

: >"$DD_LOG"
if DD_SIGNAL_PARENT=1 run_helper reconcile-hook >/dev/null 2>&1; then
	fail 'reconcile-hook must fail when terminated during replacement'
fi
DD_SIGNAL_PARENT=0
find "$TMP_DIR/openclash/custom" -name '.tailscale-openclash-hook.*' -print | grep . >/dev/null && \
	fail 'terminated hook replacement left a tracked temporary file'
grep -F 'signalled:' "$DD_LOG" >/dev/null || fail 'termination test did not reach hook replacement'

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
: >"$CHOWN_LOG"
run_helper cleanup
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
assert_count 1 '-j list table inet fw4' "$NFT_CALL_LOG"
assert_line_count 1 '-j -a list chain inet fw4 openclash_mangle_output' "$NFT_CALL_LOG"
assert_line_count 1 '-j -a list chain inet fw4 openclash_output' "$NFT_CALL_LOG"
assert_line_count 1 '-j -a list chain inet fw4 openclash_mangle' "$NFT_CALL_LOG"
assert_line_count 1 '-j -a list chain inet fw4 openclash' "$NFT_CALL_LOG"
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
: >"$NFT_CALL_LOG"
MISSING_CHAIN=openclash_output run_helper apply
[ ! -s "$NFT_BATCH_LOG" ] || fail 'missing target chain produced a partial nft transaction'
[ ! -s "$NFT_BATCH_LOG" ] || fail 'missing target chain wrote an nft batch'
assert_count 1 '-j list table inet fw4' "$NFT_CALL_LOG"
assert_count 0 '-j -a list chain inet fw4 ' "$NFT_CALL_LOG"
assert_count 0 '-f ' "$NFT_CALL_LOG"
printf '%s' "$(MISSING_CHAIN=openclash_output run_helper status)" | jq -e '.state == "waiting"' >/dev/null || \
	fail 'missing chain did not report waiting'
MISSING_CHAIN=

: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
state_before_list_failure="$(sha256sum "$NFT_STATE" | awk '{print $1}')"
if LIST_CHAIN_FAIL=openclash_output run_helper apply; then
	fail 'apply must fail when a table-enumerated chain cannot be listed'
fi
LIST_CHAIN_FAIL=
[ ! -s "$NFT_BATCH_LOG" ] || fail 'list-chain precheck failure wrote an nft batch'
assert_count 0 '-f ' "$NFT_CALL_LOG"
[ "$(sha256sum "$NFT_STATE" | awk '{print $1}')" = "$state_before_list_failure" ] || \
	fail 'list-chain precheck failure changed nft state'
printf '%s' "$(LIST_CHAIN_FAIL=openclash_output run_helper status)" | jq -e '.state == "error"' >/dev/null || \
	fail 'table-enumerated list-chain failure did not report error'
LIST_CHAIN_FAIL=

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

: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
state_before_mid_batch_failure="$(sha256sum "$NFT_STATE" | awk '{print $1}')"
if NFT_BATCH_FAIL_AFTER=1 run_helper apply; then
	fail 'apply must fail when fake nft fails after the first batch operation'
fi
NFT_BATCH_FAIL_AFTER=0
[ -s "$NFT_BATCH_LOG" ] || fail 'mid-batch failure did not submit an nft batch'
assert_count 1 '-f ' "$NFT_CALL_LOG"
[ "$(sha256sum "$NFT_STATE" | awk '{print $1}')" = "$state_before_mid_batch_failure" ] || \
	fail 'mid-batch fake nft failure changed the primary state'

if NFT_SIGNAL_PARENT=1 run_helper apply >/dev/null 2>&1; then
	fail 'apply must fail when terminated during nft replacement'
fi
NFT_SIGNAL_PARENT=0
find "$TMP_DIR/tmp" -name 'tailscale-openclash-nft.*' -print | grep . >/dev/null && \
	fail 'terminated nft reconciliation left a tracked temporary path'

: >"$NFT_BATCH_LOG"
if NFT_GENERATION_RACE=1 run_helper apply >/dev/null 2>&1; then
	fail 'apply must fail when a cached nft handle disappears before the transaction'
fi
NFT_GENERATION_RACE=0
[ "$(grep -c 'insert rule inet fw4' "$NFT_STATE")" = 3 ] || \
	fail 'generation race must expose one external deletion without partially applying the batch'
run_helper apply
[ "$(grep -c 'insert rule inet fw4' "$NFT_STATE")" = 4 ] || \
	fail 'apply did not recover after the deterministic generation race'

for false_alias in 0 false off no disabled; do
	FEATURE_ENABLED=1 run_helper sync
	FEATURE_ENABLED="$false_alias" run_helper sync
	grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null && \
		fail "false alias $false_alias left owned nft rules"
	managed_hook_present "$HOOK" && \
		fail "false alias $false_alias left the managed hook"
	printf '%s' "$(FEATURE_ENABLED="$false_alias" run_helper status)" | \
		jq -e '.state == "disabled" and .enabled == false' >/dev/null || \
		fail "false alias $false_alias did not report disabled"
done

printf '#!/bin/sh\nprintf user-only\n' >"$HOOK"
: >"$NFT_STATE"
: >"$NFT_BATCH_LOG"
unsupported_hook_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
unsupported_state_hash="$(sha256sum "$NFT_STATE" | awk '{print $1}')"
NFT_TABLE_MISSING=1 FEATURE_ENABLED=1 run_helper sync
NFT_TABLE_MISSING=0
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$unsupported_hook_hash" ] || \
	fail 'unsupported firewall4 sync changed the OpenClash hook'
[ "$(sha256sum "$NFT_STATE" | awk '{print $1}')" = "$unsupported_state_hash" ] || \
	fail 'unsupported firewall4 sync changed nft state'
[ ! -s "$NFT_BATCH_LOG" ] || fail 'unsupported firewall4 sync submitted an nft batch'
printf '%s' "$(NFT_TABLE_MISSING=1 FEATURE_ENABLED=1 run_helper status)" | jq -e '.state == "unsupported"' >/dev/null || \
	fail 'missing firewall4 table did not report unsupported'

rm -f "$TMP_DIR/openclash-init"
absent_hook_hash="$(sha256sum "$HOOK" | awk '{print $1}')"
FEATURE_ENABLED=1 run_helper sync
[ "$(sha256sum "$HOOK" | awk '{print $1}')" = "$absent_hook_hash" ] || \
	fail 'OpenClash-absent sync changed the hook'
touch "$TMP_DIR/openclash-init"
chmod +x "$TMP_DIR/openclash-init"

: >"$NFT_BATCH_LOG"
MISSING_CHAIN=openclash_output FEATURE_ENABLED=1 run_helper sync
grep -Fx '# BEGIN luci-app-tailscale 托管：Tailscale 绕过 OpenClash' "$HOOK" >/dev/null || \
	fail 'waiting sync did not install the canonical hook'
grep -Fx '	/usr/sbin/tailscale_openclash_bypass apply' "$HOOK" >/dev/null || \
	fail 'waiting sync did not install the canonical managed command'
[ ! -s "$NFT_BATCH_LOG" ] || fail 'waiting sync submitted a partial nft batch'
printf '%s' "$(MISSING_CHAIN=openclash_output FEATURE_ENABLED=1 run_helper status)" | \
	jq -e '.state == "waiting" and .hook == "managed" and .rules_present == 0' >/dev/null || \
	fail 'waiting sync did not report a canonical managed hook'
MISSING_CHAIN=

FEATURE_ENABLED=true run_helper sync
printf '%s' "$(FEATURE_ENABLED=true run_helper status)" | jq -e '.state == "active" and .rules_present == 4' >/dev/null || \
	fail 'sync did not produce active state for a true alias'

FEATURE_ENABLED=0 run_helper sync
: >"$UCI_LOG"
sync_ready="$TMP_DIR/sync-ready"
sync_release="$TMP_DIR/sync-release"
rm -f "$sync_ready" "$sync_release"
UCI_READY_FILE="$sync_ready" UCI_RELEASE_FILE="$sync_release" FEATURE_ENABLED=1 run_helper sync &
SYNC_ENABLE_PID=$!
attempt=0
while [ ! -e "$sync_ready" ]; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 100 ] || fail 'enabled sync did not reach the locked UCI read'
	sleep 0.05
done
FEATURE_ENABLED=0 run_helper sync &
SYNC_DISABLE_PID=$!
sleep 0.2
[ "$(grep -c '^-q get tailscale_openclash.settings.enabled$' "$UCI_LOG")" = 1 ] || \
	fail 'concurrent disabled sync passed the real flock before enabled sync completed'
: >"$sync_release"
wait "$SYNC_ENABLE_PID" || fail 'locked enabled sync failed'
SYNC_ENABLE_PID=
wait "$SYNC_DISABLE_PID" || fail 'serialized disabled sync failed'
SYNC_DISABLE_PID=
[ "$(grep -c '^-q get tailscale_openclash.settings.enabled$' "$UCI_LOG")" = 2 ] || \
	fail 'both serialized sync commands must re-read UCI under the lock'
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null && \
	fail 'serialized disable left owned nft rules'
managed_hook_present "$HOOK" && \
	fail 'serialized disable left the managed hook'
FEATURE_ENABLED=

: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
run_helper apply
: >"$NFT_BATCH_LOG"
: >"$NFT_CALL_LOG"
if LIST_CHAIN_FAIL=openclash_output run_helper cleanup; then
	fail 'cleanup must fail when a table-enumerated chain cannot be listed'
fi
LIST_CHAIN_FAIL=
[ ! -s "$NFT_BATCH_LOG" ] || fail 'cleanup list-chain failure wrote an nft batch'
assert_count 0 '-f ' "$NFT_CALL_LOG"
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null || fail 'list-chain cleanup failure changed owned nft rules'
run_helper reconcile-hook
if NFT_BATCH_FAIL=1 run_helper cleanup; then
	fail 'cleanup must fail when the nft delete batch fails'
fi
NFT_BATCH_FAIL=0
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null || fail 'failed cleanup batch changed owned nft rules'
managed_hook_present "$HOOK" && fail 'cleanup did not run hook cleanup before the nft batch'
run_helper reconcile-hook
printf '%s\n' '900|insert rule inet fw4 openclash iifname "tailscale0" counter comment "user-owned-rule" return' >>"$NFT_STATE"
run_helper cleanup
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null && fail 'cleanup left owned nft rules'
grep -F 'user-owned-rule' "$NFT_STATE" >/dev/null || fail 'cleanup removed a user-owned rule'
managed_hook_present "$HOOK" && fail 'cleanup left the managed hook block'

FEATURE_ENABLED=1 run_helper sync
: >"$NFT_BATCH_LOG"
NFT_TABLE_MISSING=1 run_helper cleanup
NFT_TABLE_MISSING=0
[ ! -s "$NFT_BATCH_LOG" ] || fail 'cleanup with an absent fw4 table submitted an nft batch'
: >"$NFT_STATE"

FEATURE_ENABLED=1 run_helper sync
awk '!/insert rule inet fw4 openclash_output /' "$NFT_STATE" >"$TMP_DIR/nft-with-missing-chain"
mv "$TMP_DIR/nft-with-missing-chain" "$NFT_STATE"
MISSING_CHAIN=openclash_output run_helper cleanup
MISSING_CHAIN=
grep -F 'luci-app-tailscale:' "$NFT_STATE" >/dev/null && \
	fail 'cleanup with an already absent target chain left rules from existing chains'

FEATURE_ENABLED=1 run_helper sync
: >"$NFT_DISAPPEARED_FILE"
: >"$NFT_CALL_LOG"
DISAPPEAR_CHAIN=openclash_output run_helper cleanup
DISAPPEAR_CHAIN=
[ "$(grep -c '^-j list table inet fw4$' "$NFT_CALL_LOG")" -ge 2 ] || \
	fail 'cleanup did not refresh table state after a chain disappeared'
: >"$NFT_STATE"
: >"$NFT_DISAPPEARED_FILE"

printf '%s' "$(run_helper status)" | jq -e '.state == "error"' >/dev/null || \
	fail 'incomplete managed state did not report error'

rm -f "$HOOK"
printf '%s' "$(MISSING_CHAIN=openclash_output run_helper status)" | jq -e '.state == "waiting" and .hook == "absent"' >/dev/null || \
	fail 'missing hook and target chain did not report waiting'
MISSING_CHAIN=
mkdir "$HOOK"
printf '%s' "$(run_helper status)" | jq -e '.state == "error" and .hook == "error"' >/dev/null || \
	fail 'hook read failure did not report error'
rmdir "$HOOK"

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
