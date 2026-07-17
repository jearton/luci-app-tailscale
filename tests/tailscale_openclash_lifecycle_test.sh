#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/root/etc/init.d/tailscale-openclash-bypass"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-openclash-lifecycle-test.$$"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$INIT_SCRIPT" ] || fail "missing OpenClash bypass init script"

mkdir -p "$TMP_DIR"

cat >"$TMP_DIR/fake-helper" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_HELPER_LOG:?}"
SH
chmod +x "$TMP_DIR/fake-helper"

run_sync() {
	desired_enabled="$1"
	FAKE_HELPER_LOG="$TMP_DIR/helper.log"
	: >"$FAKE_HELPER_LOG"
	export FAKE_HELPER_LOG

	(
		. "$INIT_SCRIPT"
		PROG="$TMP_DIR/fake-helper"

		config_get_bool() {
			case "$3" in
				enabled) eval "$1=$desired_enabled" ;;
				*) eval "$1=${4:-0}" ;;
			esac
		}

		sync_instance settings
	)

	cat "$FAKE_HELPER_LOG"
}

enabled_log="$(run_sync 1)"
[ "$enabled_log" = "reconcile-hook
apply" ] || fail "enabled OpenClash bypass must reconcile the hook and runtime rules"

disabled_log="$(run_sync 0)"
[ "$disabled_log" = "cleanup" ] || fail "disabled OpenClash bypass must remove only owned state"

grep -F 'procd_add_reload_trigger "tailscale_openclash"' "$INIT_SCRIPT" >/dev/null || \
	fail 'OpenClash lifecycle needs its own UCI reload trigger'
grep -F 'procd_add_reload_trigger "tailscale"' "$INIT_SCRIPT" >/dev/null && \
	fail 'OpenClash lifecycle must not subscribe to the core Tailscale UCI package'
grep -E '/etc/init.d/(tailscale|firewall|openclash)|fw4 (reload|restart)' "$INIT_SCRIPT" >/dev/null && \
	fail 'OpenClash lifecycle must not manage Tailscale, firewall4, or OpenClash services'

echo "tailscale OpenClash lifecycle tests passed"
