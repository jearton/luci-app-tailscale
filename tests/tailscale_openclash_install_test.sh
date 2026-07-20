#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UCI_DEFAULTS="$ROOT_DIR/root/etc/uci-defaults/40_luci-tailscale"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-openclash-install-test.$$"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$UCI_DEFAULTS" ] || fail "missing package UCI defaults script"
mkdir -p "$TMP_DIR/bin"

cat >"$TMP_DIR/tailscale_secrets" <<'SH'
#!/bin/sh
printf 'secrets %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
SH
chmod +x "$TMP_DIR/tailscale_secrets"

cat >"$TMP_DIR/tailscale-openclash-bypass" <<'SH'
#!/bin/sh
printf 'bypass %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
SH
chmod +x "$TMP_DIR/tailscale-openclash-bypass"

cat >"$TMP_DIR/bin/uci" <<'SH'
#!/bin/sh
printf 'uci %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
cat >/dev/null
SH
chmod +x "$TMP_DIR/bin/uci"

cat >"$TMP_DIR/tailscale" <<'SH'
#!/bin/sh
printf 'tailscale %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
SH
chmod +x "$TMP_DIR/tailscale"

run_defaults() {
	mode="$1"
	: >"$TMP_DIR/lifecycle.log"
	if [ "$mode" = "without-bypass" ]; then
		rm -f "$TMP_DIR/tailscale-openclash-bypass"
	fi
	# Run an isolated copy so the package script's production absolute paths use
	# the test fixtures without adding test-only hooks to the package itself.
	sed \
		-e "s#/usr/sbin/tailscale_secrets#$TMP_DIR/tailscale_secrets#g" \
		-e "s#/etc/init.d/tailscale-openclash-bypass#$TMP_DIR/tailscale-openclash-bypass#g" \
		"$UCI_DEFAULTS" >"$TMP_DIR/uci-defaults"
	chmod +x "$TMP_DIR/uci-defaults"

	PATH="$TMP_DIR/bin:$PATH" \
	LIFECYCLE_LOG="$TMP_DIR/lifecycle.log" \
	sh "$TMP_DIR/uci-defaults"

	cat "$TMP_DIR/lifecycle.log"
}

enabled_log="$(run_defaults enabled)"
expected_enabled='secrets migrate
uci -q batch
bypass enable
bypass start'
[ "$enabled_log" = "$expected_enabled" ] || fail "package defaults must migrate credentials, update ucitrack, then enable and start bypass\nactual:\n$enabled_log"

cat >"$TMP_DIR/tailscale-openclash-bypass" <<'SH'
#!/bin/sh
printf 'bypass %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
SH
chmod +x "$TMP_DIR/tailscale-openclash-bypass"

absent_log="$(run_defaults without-bypass)"
expected_absent='secrets migrate
uci -q batch'
[ "$absent_log" = "$expected_absent" ] || fail "missing bypass init script must not fail package defaults\nactual:\n$absent_log"

run_prerm() {
	mode="$1"
	awk '
		/^define Package\/luci-app-tailscale\/prerm$/ { in_prerm = 1; next }
		in_prerm && /^endef$/ { exit }
		in_prerm { print }
	' "$ROOT_DIR/Makefile" \
	| sed \
		-e 's/\$\${/${/g' \
		-e "s#/usr/sbin/tailscale_openclash_bypass#$TMP_DIR/tailscale_openclash_bypass#g" \
		-e "s#/etc/init.d/tailscale-openclash-bypass#$TMP_DIR/tailscale-openclash-bypass#g" \
		-e "s#/etc/init.d/tailscale#$TMP_DIR/tailscale#g" \
		>"$TMP_DIR/prerm"
	chmod +x "$TMP_DIR/prerm"

	cat >"$TMP_DIR/tailscale_openclash_bypass" <<'SH'
#!/bin/sh
printf 'helper %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
SH
	chmod +x "$TMP_DIR/tailscale_openclash_bypass"

	cat >"$TMP_DIR/tailscale-openclash-bypass" <<'SH'
#!/bin/sh
printf 'bypass %s\n' "$*" >>"${LIFECYCLE_LOG:?}"
SH
	chmod +x "$TMP_DIR/tailscale-openclash-bypass"

	: >"$TMP_DIR/lifecycle.log"
	IPKG_INSTROOT='' LIFECYCLE_LOG="$TMP_DIR/lifecycle.log" sh "$TMP_DIR/prerm" "$mode"
	cat "$TMP_DIR/lifecycle.log"
}

upgrade_prerm_log="$(run_prerm upgrade)"
[ -z "$upgrade_prerm_log" ] || fail "package upgrade must preserve helper rules, bypass startup, and Tailscale\nactual:\n$upgrade_prerm_log"

prerm_log="$(run_prerm remove)"
expected_prerm='helper cleanup
bypass disable
tailscale stop'
[ "$prerm_log" = "$expected_prerm" ] || fail "package removal must clean helper rules, disable bypass boot startup, then stop Tailscale\nactual:\n$prerm_log"

echo "tailscale OpenClash install lifecycle tests passed"
