#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_helper"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-helper-test.$$"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_contains() {
	needle="$1"
	haystack="$2"
	message="$3"

	printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null || fail "$message
missing: $needle"
}

assert_not_contains() {
	needle="$1"
	haystack="$2"
	message="$3"

	if printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null; then
		fail "$message
unexpected: $needle"
	fi
}

body="$(cat "$SCRIPT")"

assert_contains "uci -q delete network.tailscale" "$body" "helper should remove the legacy LuCI network interface wrapper"
assert_contains "add_list firewall.tszone.device='tailscale0'" "$body" "firewall zone should bind directly to tailscale0"
assert_contains "uci commit firewall && { \"\$FIREWALL_INIT\" reload || \"\$FIREWALL_INIT\" restart; }" "$body" "helper should restart firewall when reload cannot apply committed rules"

assert_not_contains "set network.tailscale='interface'" "$body" "helper must not recreate a LuCI network interface for tailscale0"
assert_not_contains "set network.tailscale.proto" "$body" "helper must not configure a netifd protocol for tailscale0"
assert_not_contains "set network.ts_subnet" "$body" "helper must not create static netifd routes for Tailscale subnet routes"
assert_not_contains "add_list firewall.tszone.network='tailscale'" "$body" "firewall zone should not depend on a LuCI network interface"

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state"

cat >"$TMP_DIR/uci_db" <<'EOF'
firewall.@defaults[0].forward=ACCEPT
firewall.@forwarding[0]=forwarding
firewall.@forwarding[0].src=lan
firewall.@forwarding[0].dest=wan
EOF

cat >"$TMP_DIR/bin/uci" <<'SH'
#!/bin/sh
set -eu

db="${UCI_DB:?}"
changes="${UCI_CHANGES_LOG:?}"
quiet=0

if [ "${1:-}" = "-q" ]; then
	quiet=1
	shift
fi

cmd="${1:-}"
[ -n "$cmd" ] || exit 1
shift || true

get_value() {
	key="$1"
	awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); found=1; exit } END { if (!found) exit 1 }' "$db"
}

has_key() {
	key="$1"
	awk -F= -v key="$key" '$1 == key { found=1; exit } END { exit(found ? 0 : 1) }' "$db"
}

set_value() {
	key="$1"
	value="$2"
	tmp="$db.tmp"
	awk -F= -v key="$key" -v value="$value" '
		BEGIN { replaced=0 }
		$1 == key {
			print key "=" value
			replaced=1
			next
		}
		{ print }
		END {
			if (!replaced) {
				print key "=" value
			}
		}
	' "$db" >"$tmp"
	mv "$tmp" "$db"
	printf 'set %s=%s\n' "$key" "$value" >>"$changes"
}

delete_value() {
	key="$1"
	tmp="$db.tmp"
	awk -F= -v key="$key" '$1 != key { print }' "$db" >"$tmp"
	mv "$tmp" "$db"
	printf 'delete %s\n' "$key" >>"$changes"
}

show_prefix() {
	prefix="$1"
	awk -F= -v prefix="$prefix" '$1 ~ "^" prefix { print }' "$db"
}

case "$cmd" in
	get)
		get_value "$1"
		;;
	set)
		key="${1%%=*}"
		value="${1#*=}"
		set_value "$key" "$value"
		;;
	delete)
		if has_key "$1"; then
			delete_value "$1"
		else
			[ "$quiet" -eq 1 ] || exit 1
		fi
		;;
	show)
		show_prefix "${1:-}"
		;;
	changes)
		if [ -s "$changes" ]; then
			cat "$changes"
		fi
		;;
	commit)
		: >"$changes"
		printf 'commit %s\n' "${1:-}" >>"${UCI_COMMIT_LOG:?}"
		;;
	revert)
		printf 'revert %s\n' "${1:-}" >>"${UCI_REVERT_LOG:?}"
		;;
	*)
		echo "unsupported fake uci command: $cmd" >&2
		exit 1
		;;
esac
SH
chmod +x "$TMP_DIR/bin/uci"

cat >"$TMP_DIR/bin/flock" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TMP_DIR/bin/flock"

cat >"$TMP_DIR/bin/ifconfig" <<'SH'
#!/bin/sh
printf 'tailscale0 Link encap:Ethernet\n'
SH
chmod +x "$TMP_DIR/bin/ifconfig"

cat >"$TMP_DIR/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod +x "$TMP_DIR/bin/logger"

cat >"$TMP_DIR/bin/tailscale" <<'SH'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"${TAILSCALE_LOG:?}"

case "${1:-}" in
	up)
		exit 0
		;;
	ip)
		[ "${2:-}" = "-4" ] || exit 1
		printf '100.64.0.10\n'
		;;
	status)
		printf '{"MagicDNSSuffix":"example.tailnet"}\n'
		;;
	*)
		echo "unsupported fake tailscale command: $*" >&2
		exit 1
		;;
esac
SH
chmod +x "$TMP_DIR/bin/tailscale"

cat >"$TMP_DIR/firewall-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FIREWALL_LOG:?}"
SH
chmod +x "$TMP_DIR/firewall-init"

cat >"$TMP_DIR/tailscale-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${TAILSCALE_INIT_LOG:?}"
SH
chmod +x "$TMP_DIR/tailscale-init"

cat >"$TMP_DIR/dnsmasq-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${DNSMASQ_LOG:?}"
SH
chmod +x "$TMP_DIR/dnsmasq-init"

run_helper() {
	exit_node="$1"
	ACCESS=
	ACCEPT_DNS=0
	DISABLE_SNAT_SUBNET_ROUTES=0
	UCI_DB="$TMP_DIR/uci_db"
	UCI_CHANGES_LOG="$TMP_DIR/uci_changes.log"
	UCI_COMMIT_LOG="$TMP_DIR/uci_commit.log"
	UCI_REVERT_LOG="$TMP_DIR/uci_revert.log"
	TAILSCALE_LOG="$TMP_DIR/tailscale.log"
	LOGGER_LOG="$TMP_DIR/logger.log"
	FIREWALL_LOG="$TMP_DIR/firewall.log"
	TAILSCALE_INIT_LOG="$TMP_DIR/tailscale-init.log"
	DNSMASQ_LOG="$TMP_DIR/dnsmasq.log"
	PATH="$TMP_DIR/bin:$PATH"
	TAILSCALE_BIN="$TMP_DIR/bin/tailscale"
	IFCONFIG_BIN="$TMP_DIR/bin/ifconfig"
	FLOCK_BIN="$TMP_DIR/bin/flock"
	LOCK_FILE="$TMP_DIR/tailscale.lock"
	LOGGER_CMD="$TMP_DIR/bin/logger"
	FIREWALL_INIT="$TMP_DIR/firewall-init"
	TAILSCALE_INIT="$TMP_DIR/tailscale-init"
	DNSMASQ_INIT="$TMP_DIR/dnsmasq-init"
	TAILSCALE_HELPER_STATE_DIR="$TMP_DIR/state"
	export ACCESS ACCEPT_DNS DISABLE_SNAT_SUBNET_ROUTES UCI_DB UCI_CHANGES_LOG UCI_COMMIT_LOG UCI_REVERT_LOG
	export TAILSCALE_LOG LOGGER_LOG FIREWALL_LOG TAILSCALE_INIT_LOG DNSMASQ_LOG PATH
	export TAILSCALE_BIN IFCONFIG_BIN FLOCK_BIN LOCK_FILE LOGGER_CMD FIREWALL_INIT TAILSCALE_INIT DNSMASQ_INIT TAILSCALE_HELPER_STATE_DIR
	EXIT_NODE="$exit_node" export EXIT_NODE

	if ! "$SCRIPT"; then
		printf 'helper failed for EXIT_NODE=%s\n' "$exit_node" >&2
		[ -s "$LOGGER_LOG" ] && { printf 'logger:\n' >&2; cat "$LOGGER_LOG" >&2; }
		[ -s "$TAILSCALE_INIT_LOG" ] && { printf 'tailscale-init:\n' >&2; cat "$TAILSCALE_INIT_LOG" >&2; }
		[ -s "$UCI_REVERT_LOG" ] && { printf 'uci-revert:\n' >&2; cat "$UCI_REVERT_LOG" >&2; }
		return 1
	fi
}

: >"$TMP_DIR/uci_changes.log"
: >"$TMP_DIR/uci_commit.log"
: >"$TMP_DIR/uci_revert.log"
: >"$TMP_DIR/tailscale.log"
: >"$TMP_DIR/logger.log"
: >"$TMP_DIR/firewall.log"
: >"$TMP_DIR/tailscale-init.log"
: >"$TMP_DIR/dnsmasq.log"

run_helper "peer-exit-node"

enabled_forward="$(awk -F= '$1 == "firewall.@defaults[0].forward" { print $2 }' "$TMP_DIR/uci_db")"
[ "$enabled_forward" = "REJECT" ] || fail "exit node enable should force firewall default forward to REJECT
actual: $enabled_forward"

enabled_override="$(awk -F= '$1 == "firewall.@forwarding[0].enabled" { print $2 }' "$TMP_DIR/uci_db")"
[ "$enabled_override" = "0" ] || fail "exit node enable should disable the LAN to WAN forwarding rule
actual: ${enabled_override:-missing}"

[ -f "$TMP_DIR/state/exit_node_firewall_state" ] || fail "exit node enable should persist firewall restore state"

run_helper ""

restored_forward="$(awk -F= '$1 == "firewall.@defaults[0].forward" { print $2 }' "$TMP_DIR/uci_db")"
[ "$restored_forward" = "ACCEPT" ] || fail "non-exit-node helper run should restore the previous firewall forward policy
actual: $restored_forward"

if awk -F= '$1 == "firewall.@forwarding[0].enabled" { found=1 } END { exit(found ? 0 : 1) }' "$TMP_DIR/uci_db"; then
	fail "non-exit-node helper run should remove the temporary LAN to WAN enabled override"
fi

[ ! -f "$TMP_DIR/state/exit_node_firewall_state" ] || fail "helper should clear the exit-node firewall restore state after reconciliation"

assert_contains "reload" "$(cat "$TMP_DIR/firewall.log")" "helper should reload firewall after restoring exit-node changes"

echo "tailscale_helper network cleanup tests passed"
