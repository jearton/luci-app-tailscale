#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/root/usr/sbin/tailscale_keepalive"
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

printf 'tailscale_keepalive resolver tests passed\n'
