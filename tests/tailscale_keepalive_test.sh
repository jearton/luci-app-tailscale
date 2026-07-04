#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_keepalive"
INIT_SCRIPT="$ROOT_DIR/root/etc/init.d/tailscale"
TMP_DIR="${TMPDIR:-/tmp}/tailscale-keepalive-test.$$"
STATUS_FILE="$TMP_DIR/status.json"

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

cat >"$STATUS_FILE" <<'JSON'
{
  "Peer": {
    "nodekey:one": {
      "HostName": "site-a-openwrt",
      "DNSName": "site-a-openwrt.example.tailnet.",
      "TailscaleIPs": [
        "100.64.100.2",
        "fd7a:115c:a1e0::2"
      ]
    },
    "nodekey:two": {
      "HostName": "site-b-gateway",
      "DNSName": "site-b-gateway.example.tailnet.",
      "TailscaleIPs": [
        "100.64.100.1"
      ]
    },
    "nodekey:three": {
      "HostName": "no-ip-peer",
      "DNSName": "no-ip-peer.litata.tailnet.",
      "TailscaleIPs": []
    }
  }
}
JSON

output="$(TAILSCALE_STATUS_FILE="$STATUS_FILE" "$SCRIPT" --resolve-peers \
		site-a-openwrt \
		site-b-gateway.example.tailnet \
		missing-peer \
		no-ip-peer)"

expected="$(printf '%s\t%s\t%s\n%s\t%s\t%s\n%s\t%s\t%s\n%s\t%s\t%s' \
	site-a-openwrt OK 100.64.100.2 \
	site-b-gateway.example.tailnet OK 100.64.100.1 \
	missing-peer NOT_FOUND '' \
	no-ip-peer NO_IP '')"

if [ "$output" != "$expected" ]; then
	printf 'unexpected resolver output\nexpected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
	exit 1
fi

cat >"$STATUS_FILE" <<'JSON'
{"Peer":{"nodekey:one":{"TailscaleIPs":["100.64.100.9"],"DNSName":"compact-peer.example.tailnet.","HostName":"compact-peer"},"nodekey:two":{"DNSName":"reordered.example.tailnet.","HostName":"reordered-peer","Online":true,"TailscaleIPs":["100.64.100.10"]}}}
JSON

output="$(TAILSCALE_STATUS_FILE="$STATUS_FILE" "$SCRIPT" --resolve-peers \
		compact-peer \
		reordered.example.tailnet)"

expected="$(printf '%s\t%s\t%s\n%s\t%s\t%s' \
	compact-peer OK 100.64.100.9 \
	reordered.example.tailnet OK 100.64.100.10)"

if [ "$output" != "$expected" ]; then
	printf 'unexpected compact resolver output\nexpected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
	exit 1
fi

cat >"$TMP_DIR/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$LOGGER_OUTPUT"
SH
chmod +x "$TMP_DIR/logger"

LOGGER_OUTPUT="$TMP_DIR/logger.out"
PATH="$TMP_DIR:$PATH"
export LOGGER_OUTPUT PATH

(
	config_get_bool() {
		eval "$1=1"
	}

	config_get() {
		case "$3" in
			keepalive_peers) eval "$1=" ;;
			keepalive_interval) eval "$1=20" ;;
			keepalive_failure_log_interval) eval "$1=300" ;;
			log_stdout|log_stderr) eval "$1=0" ;;
			*) eval "$1=" ;;
		esac
	}

	procd_open_instance() { :; }
	procd_set_param() { :; }
	procd_append_param() { :; }
	procd_close_instance() { :; }

	. "$INIT_SCRIPT"
	tailscale_keepalive cfg
)

if ! grep -q 'keepalive enabled but no peers configured' "$LOGGER_OUTPUT"; then
	printf 'expected init script to log empty keepalive peers\n' >&2
	exit 1
fi

printf 'tailscale_keepalive resolver tests passed\n'
