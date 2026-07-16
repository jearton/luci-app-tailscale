#!/usr/bin/env bash

set -euo pipefail

: "${SDK_IMAGE:?SDK_IMAGE is required}"
: "${PACKAGE_FEED_DIR:?PACKAGE_FEED_DIR is required}"
: "${ARTIFACTS_DIR:?ARTIFACTS_DIR is required}"

PACKAGE_NAME="${PACKAGE_NAME:-luci-app-tailscale}"
PACKAGE_FEED_DIR="$(cd "$PACKAGE_FEED_DIR" && pwd -P)"
ARTIFACTS_DIR="$(cd "$ARTIFACTS_DIR" && pwd -P)"
SDK_BUILD_SCRIPT="$PACKAGE_FEED_DIR/.github/scripts/openwrt-sdk-build.sh"

test -r "$SDK_BUILD_SCRIPT"

restore_ownership() {
	sudo chown -R --reference="$ARTIFACTS_DIR/.." "$ARTIFACTS_DIR" || true
}
trap restore_ownership EXIT

sudo chown -R 1000:1000 "$ARTIFACTS_DIR"
docker pull "$SDK_IMAGE"
docker run --rm \
	--env "BUILD_LOG=${BUILD_LOG:-1}" \
	--env "PACKAGE_NAME=$PACKAGE_NAME" \
	--env "V=${V:-s}" \
	--volume "$ARTIFACTS_DIR:/artifacts" \
	--volume "$PACKAGE_FEED_DIR:/feed" \
	--volume "$SDK_BUILD_SCRIPT:/usr/local/bin/openwrt-sdk-build:ro" \
	--entrypoint /bin/bash \
	"$SDK_IMAGE" \
	/usr/local/bin/openwrt-sdk-build
