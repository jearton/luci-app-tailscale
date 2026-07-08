#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_helper"

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

assert_not_contains "set network.tailscale='interface'" "$body" "helper must not recreate a LuCI network interface for tailscale0"
assert_not_contains "set network.tailscale.proto" "$body" "helper must not configure a netifd protocol for tailscale0"
assert_not_contains "set network.ts_subnet" "$body" "helper must not create static netifd routes for Tailscale subnet routes"
assert_not_contains "add_list firewall.tszone.network='tailscale'" "$body" "firewall zone should not depend on a LuCI network interface"

echo "tailscale_helper network cleanup tests passed"
