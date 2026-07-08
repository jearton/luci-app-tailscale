#!/bin/sh

# Copyright (C) 2026 jearton
# SPDX-License-Identifier: GPL-3.0-only

. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

SERVICE=/etc/init.d/tailscale
IFNAME=tailscale0
WAIT_TIMEOUT=30

proto_tailscale_init_config() {
	no_device=1
	available=1
}

wait_tailscale_device() {
	local count=0

	while [ "$count" -lt "$WAIT_TIMEOUT" ]; do
		ip link show "$IFNAME" >/dev/null 2>&1 && return 0
		sleep 1
		count=$((count + 1))
	done

	return 1
}

proto_tailscale_setup() {
	local config="$1"

	"$SERVICE" start || {
		proto_notify_error "$config" "SERVICE_START_FAILED"
		return 1
	}

	if ! wait_tailscale_device; then
		proto_notify_error "$config" "DEVICE_TIMEOUT"
		return 1
	fi

	proto_init_update "$IFNAME" 1
	proto_send_update "$config"
}

proto_tailscale_teardown() {
	local config="$1"

	"$SERVICE" stop
	proto_init_update "*" 0
	proto_send_update "$config"
}

add_protocol tailscale
