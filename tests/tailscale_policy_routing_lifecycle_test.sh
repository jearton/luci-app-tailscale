#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/root/etc/init.d/tailscale-policy-routing"
HOTPLUG_SCRIPT="$ROOT_DIR/root/etc/hotplug.d/iface/98-tailscale-policy-routing"
UCI_CONFIG="$ROOT_DIR/root/etc/config/tailscale_policy_routing"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-policy-routing-lifecycle-test.$$"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -x "$INIT_SCRIPT" ] || fail "missing policy-routing init script"
[ -x "$HOTPLUG_SCRIPT" ] || fail "missing policy-routing hotplug script"
[ -f "$UCI_CONFIG" ] || fail "missing policy-routing UCI config"
grep -qx "config settings 'settings'" "$UCI_CONFIG" || fail 'policy-routing UCI config must use a settings section'

mkdir -p "$TMP_DIR"
cat >"$TMP_DIR/fake-helper" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_HELPER_LOG:?}"
SH
chmod +x "$TMP_DIR/fake-helper"

run_service() {
	entrypoint="$1"
	FAKE_HELPER_LOG="$TMP_DIR/helper.log"
	: >"$FAKE_HELPER_LOG"
	export FAKE_HELPER_LOG
	(
		. "$INIT_SCRIPT"
		PROG="$TMP_DIR/fake-helper"
		"$entrypoint"
	)
	cat "$FAKE_HELPER_LOG"
}

[ "$(run_service start_service)" = "sync" ] || fail 'start must synchronize the helper'
[ "$(run_service reload_service)" = "sync" ] || fail 'reload must synchronize the helper'
[ -z "$(run_service stop_service)" ] || fail 'ordinary stop must preserve persistent policy-routing configuration'

grep -F 'procd_add_reload_trigger "tailscale_policy_routing"' "$INIT_SCRIPT" >/dev/null || \
	fail 'policy-routing service needs its own UCI reload trigger'
grep -E '/etc/init.d/(tailscale|firewall|mwan3|openclash)|fw4 (reload|restart)|mwan3 restart' "$INIT_SCRIPT" "$HOTPLUG_SCRIPT" >/dev/null && \
	fail 'policy-routing lifecycle must not manage Tailscale, firewall, mwan3, or OpenClash services'

echo 'tailscale policy-routing lifecycle tests passed'
