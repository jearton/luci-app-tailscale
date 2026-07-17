#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/root/etc/init.d/tailscale-openclash-bypass"
UCI_CONFIG="$ROOT_DIR/root/etc/config/tailscale_openclash"
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
[ -f "$UCI_CONFIG" ] || fail "missing OpenClash bypass UCI config"
grep -qx "config openclash 'settings'" "$UCI_CONFIG" || \
	fail 'OpenClash bypass UCI config must use the openclash section type'

mkdir -p "$TMP_DIR"

cat >"$TMP_DIR/fake-helper" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_HELPER_LOG:?}"
SH
chmod +x "$TMP_DIR/fake-helper"

run_service() {
	desired_enabled="$1"
	service_entrypoint="$2"
	script_path="${3:-$INIT_SCRIPT}"
	FAKE_HELPER_LOG="$TMP_DIR/helper.log"
	: >"$FAKE_HELPER_LOG"
	export FAKE_HELPER_LOG

	rc=0
	(
		. "$script_path"
		PROG="$TMP_DIR/fake-helper"

		config_load() {
			[ "$#" -eq 1 ] || fail 'config_load must receive exactly one package name'
			[ "$1" = "tailscale_openclash" ] || \
				fail 'start lifecycle must load the tailscale_openclash UCI package'
		}

		config_foreach() {
			[ "$#" -eq 2 ] || fail 'config_foreach must receive a callback and section type'
			[ "$1" = "sync_instance" ] || \
				fail 'start lifecycle must dispatch through sync_instance'
			[ "$2" = "openclash" ] || \
				fail 'start lifecycle must iterate openclash sections only'
			"$1" settings
		}

		config_get_bool() {
			[ "$#" -eq 4 ] || fail 'enabled lookup must include a default value'
			[ "$1" = "enabled" ] || fail 'enabled lookup must set the enabled variable'
			[ "$2" = "settings" ] || fail 'enabled lookup must use the iterated section'
			[ "$3" = "enabled" ] || fail 'enabled lookup must read the enabled option'
			[ "$4" = "1" ] || fail 'enabled lookup must default to enabled'
			eval "$1=$desired_enabled"
		}

		"$service_entrypoint"
	) || rc=$?
	[ "$rc" -eq 0 ] || return "$rc"

	cat "$FAKE_HELPER_LOG"
}

enabled_start_log="$(run_service 1 start_service)"
[ "$enabled_start_log" = "reconcile-hook
apply" ] || fail "enabled OpenClash bypass must reconcile the hook and runtime rules"

enabled_reload_log="$(run_service 1 reload_service)"
[ "$enabled_reload_log" = "reconcile-hook
apply" ] || fail "reload must reconcile the enabled OpenClash bypass"

disabled_start_log="$(run_service 0 start_service)"
[ "$disabled_start_log" = "cleanup" ] || fail "disabled OpenClash bypass must remove only owned state"

disabled_reload_log="$(run_service 0 reload_service)"
[ "$disabled_reload_log" = "cleanup" ] || fail "reload must remove disabled OpenClash bypass state"

bad_package_script="$TMP_DIR/init-wrong-package"
sed 's/config_load tailscale_openclash/config_load tailscale/' "$INIT_SCRIPT" >"$bad_package_script"
if run_service 1 start_service "$bad_package_script" >/dev/null 2>&1; then
	fail 'lifecycle test must reject an incorrect UCI package name'
fi

bad_callback_script="$TMP_DIR/init-wrong-callback"
sed 's/config_foreach sync_instance openclash/config_foreach wrong_callback openclash/' "$INIT_SCRIPT" >"$bad_callback_script"
if run_service 1 start_service "$bad_callback_script" >/dev/null 2>&1; then
	fail 'lifecycle test must reject an incorrect config_foreach callback'
fi

bad_section_type_script="$TMP_DIR/init-wrong-section-type"
sed 's/config_foreach sync_instance openclash/config_foreach sync_instance tailscale/' "$INIT_SCRIPT" >"$bad_section_type_script"
if run_service 1 start_service "$bad_section_type_script" >/dev/null 2>&1; then
	fail 'lifecycle test must reject an incorrect config_foreach section type'
fi

grep -F 'procd_add_reload_trigger "tailscale_openclash"' "$INIT_SCRIPT" >/dev/null || \
	fail 'OpenClash lifecycle needs its own UCI reload trigger'
grep -F 'procd_add_reload_trigger "tailscale"' "$INIT_SCRIPT" >/dev/null && \
	fail 'OpenClash lifecycle must not subscribe to the core Tailscale UCI package'
grep -E '/etc/init.d/(tailscale|firewall|openclash)|fw4 (reload|restart)' "$INIT_SCRIPT" >/dev/null && \
	fail 'OpenClash lifecycle must not manage Tailscale, firewall4, or OpenClash services'

echo "tailscale OpenClash lifecycle tests passed"
