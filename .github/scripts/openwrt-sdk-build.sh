#!/usr/bin/env bash

set -euo pipefail

: "${PACKAGE_NAME:?PACKAGE_NAME is required}"

collect_outputs() {
	if [[ -d bin ]]; then
		mv bin /artifacts/
	fi
	if [[ -d logs ]]; then
		mv logs /artifacts/
	fi
}
trap collect_outputs EXIT

if [[ -f setup.sh ]]; then
	bash setup.sh
fi

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default >feeds.conf
printf 'src-link local /feed/\n' >>feeds.conf

./scripts/feeds update -a
make defconfig
./scripts/feeds install -p local -f "$PACKAGE_NAME"

make \
	BUILD_LOG="${BUILD_LOG:-1}" \
	"package/$PACKAGE_NAME/download" \
	V=s

set +e
make \
	BUILD_LOG="${BUILD_LOG:-1}" \
	"package/$PACKAGE_NAME/check" \
	V=s 2>&1 | tee package-check.log
check_status="${PIPESTATUS[0]}"
set -e

if [[ "$check_status" -ne 0 ]]; then
	echo "Package check failed" >&2
	exit "$check_status"
fi

if grep -qE 'HASH does not match |HASH uses deprecated hash,|HASH is missing,' package-check.log; then
	echo "Package HASH check failed" >&2
	exit 1
fi

make \
	BUILD_LOG="${BUILD_LOG:-1}" \
	CONFIG_AUTOREMOVE=y \
	V="${V:-s}" \
	-j "$(nproc)" \
	"package/$PACKAGE_NAME/compile"
