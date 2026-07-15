#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT_SCRIPT="$ROOT_DIR/root/etc/init.d/tailscale"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-init-adguard-test.$$"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$TMP_DIR"

cat >"$TMP_DIR/fake-adguard" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_ADGUARD_LOG:?}"
SH
chmod +x "$TMP_DIR/fake-adguard"

cat >"$TMP_DIR/fake-helper" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_HELPER_LOG:?}"
SH
chmod +x "$TMP_DIR/fake-helper"

run_apply_down() {
	switch_enabled="$1"
	state_profile="${2:-}"
	FAKE_ADGUARD_LOG="$TMP_DIR/adguard.log"
	ADGUARD_DNS_STATE_DIR="$TMP_DIR/state"
	: >"$FAKE_ADGUARD_LOG"
	rm -rf "$ADGUARD_DNS_STATE_DIR"
	if [ -n "$state_profile" ]; then
		mkdir -p "$ADGUARD_DNS_STATE_DIR"
		printf '%s\n' "$state_profile" >"$ADGUARD_DNS_STATE_DIR/current_profile"
	fi
	export FAKE_ADGUARD_LOG ADGUARD_DNS_STATE_DIR

	(
		. "$INIT_SCRIPT"
		PROGA="$TMP_DIR/fake-adguard"
		ADGUARD_DNS_STATE_DIR="$ADGUARD_DNS_STATE_DIR"

		config_get_bool() {
			case "$3" in
				adguard_dns_switch_enabled) eval "$1=$switch_enabled" ;;
				*) eval "$1=${4:-0}" ;;
			esac
		}

		config_get() {
			case "$3" in
				adguard_default_upstreams) eval "$1=223.5.5.5" ;;
				*) eval "$1=" ;;
			esac
		}

		tailscale_adguard_dns_apply_down settings
	)

	cat "$FAKE_ADGUARD_LOG"
}

run_stop_instance() {
	FAKE_ADGUARD_LOG="$TMP_DIR/stop-adguard.log"
	FAKE_HELPER_LOG="$TMP_DIR/helper.log"
	ADGUARD_DNS_STATE_DIR="$TMP_DIR/stop-state"
	CONFIG_DIR="$TMP_DIR/config"
	UCI_CHANGES_OUT="$TMP_DIR/uci-changes.out"
	TAILSCALE_STATUS_OUT="$TMP_DIR/tailscale-status.out"
	TAILSCALED_CLEANUP_LOG="$TMP_DIR/tailscaled-cleanup.log"
	rm -rf "$ADGUARD_DNS_STATE_DIR" "$CONFIG_DIR"
	: >"$FAKE_ADGUARD_LOG"
	: >"$FAKE_HELPER_LOG"
	: >"$UCI_CHANGES_OUT"
	: >"$TAILSCALE_STATUS_OUT"
	: >"$TAILSCALED_CLEANUP_LOG"
	mkdir -p "$ADGUARD_DNS_STATE_DIR" "$CONFIG_DIR"
	printf 'up\n' >"$ADGUARD_DNS_STATE_DIR/current_profile"
	export FAKE_ADGUARD_LOG FAKE_HELPER_LOG ADGUARD_DNS_STATE_DIR CONFIG_DIR UCI_CHANGES_OUT TAILSCALE_STATUS_OUT TAILSCALED_CLEANUP_LOG

	(
		. "$INIT_SCRIPT"
		PROGA="$TMP_DIR/fake-adguard"
		PROG="$TMP_DIR/fake-helper"
		PROGD="$TMP_DIR/fake-tailscaled"
		CONFIG_PATH="$CONFIG_DIR"
		ADGUARD_DNS_STATE_DIR="$ADGUARD_DNS_STATE_DIR"

		config_get_bool() {
			case "$3" in
				adguard_dns_switch_enabled) eval "$1=0" ;;
				*) eval "$1=${4:-0}" ;;
			esac
		}

		config_get() {
			case "$3" in
				adguard_default_upstreams) eval "$1=223.5.5.5" ;;
				*) eval "$1=" ;;
			esac
		}

		tailscale() {
			case "$1" in
				status)
					printf '{"MagicDNSSuffix":"example.tailnet"}\n' >"$TAILSCALE_STATUS_OUT"
					printf '{"MagicDNSSuffix":"example.tailnet"}\n'
					;;
				*)
					return 1
					;;
			esac
		}

		uci() {
			case "$1" in
				show)
					:
					;;
				changes)
					cat "$UCI_CHANGES_OUT"
					;;
				commit)
					:
					;;
				-q)
					shift
					case "$1" in
						del_list)
							:
							;;
						*)
							return 1
							;;
					esac
					;;
				*)
					return 1
					;;
			esac
		}

		rm() {
			command rm "$@"
		}

		stop_instance settings
	)
}

cat >"$TMP_DIR/fake-tailscaled" <<'SH'
#!/bin/sh
[ "${1:-}" = "--cleanup" ] || exit 1
printf '%s\n' "$*" >>"${TAILSCALED_CLEANUP_LOG:?}"
SH
chmod +x "$TMP_DIR/fake-tailscaled"

disabled_output="$(run_apply_down 0)"
[ -z "$disabled_output" ] || fail "disabled AdGuard DNS switch must not apply down profile
actual: $disabled_output"

enabled_output="$(run_apply_down 1)"
[ "$enabled_output" = "--apply-profile down" ] || fail "enabled AdGuard DNS switch should apply down profile
actual: $enabled_output"

disabled_with_managed_profile_output="$(run_apply_down 0 up)"
[ "$disabled_with_managed_profile_output" = "--apply-profile down" ] || fail "disabling a managed AdGuard DNS switch should restore the down profile
actual: $disabled_with_managed_profile_output"

run_stop_instance

helper_output="$(cat "$TMP_DIR/helper.log")"
[ "$helper_output" = "--cleanup-exit-node-firewall
--cleanup-wan-direct-firewall" ] || fail "stop_instance should clean up exit-node and WAN-direct firewall state
actual: ${helper_output:-<empty>}"

normalized_default="$(
	. "$INIT_SCRIPT"
	normalize_tailscale_port ""
)"
[ "$normalized_default" = "41641" ] || fail "empty Tailscale port should normalize to 41641"

normalized_invalid="$(
	. "$INIT_SCRIPT"
	normalize_tailscale_port "invalid"
)"
[ "$normalized_invalid" = "41641" ] || fail "non-numeric Tailscale port should normalize to 41641"

normalized_out_of_range="$(
	. "$INIT_SCRIPT"
	normalize_tailscale_port "70000"
)"
[ "$normalized_out_of_range" = "41641" ] || fail "out-of-range Tailscale port should normalize to 41641"

normalized_custom="$(
	. "$INIT_SCRIPT"
	normalize_tailscale_port "42424"
)"
[ "$normalized_custom" = "42424" ] || fail "valid Tailscale port should be preserved"

echo "tailscale init AdGuard lifecycle tests passed"
