#!/bin/sh

set -eu

workflow=.github/workflows/release.yml
build_job="$(sed -n '/^  build:/,/^  release:/p' "$workflow")"

printf '%s\n' "$build_job" | grep -F 'path: luci-app-tailscale' >/dev/null
printf '%s\n' "$build_job" | grep -F 'if [[ -d logs ]]; then' >/dev/null
grep -F 'name: Verify release tag matches package version' "$workflow" >/dev/null
grep -F 'GITHUB_REF_NAME' "$workflow" >/dev/null
grep -F 'PKG_VERSION:=' "$workflow" >/dev/null
grep -F "luci-i18n-tailscale-zh-cn_*.ipk" "$workflow" >/dev/null
grep -F "luci-i18n-tailscale-zh-tw_*.ipk" "$workflow" >/dev/null
grep -F "luci-i18n-tailscale-zh-cn-*.apk" "$workflow" >/dev/null
grep -F "luci-i18n-tailscale-zh-tw-*.apk" "$workflow" >/dev/null
grep -F 'expected exactly one artifact' "$workflow" >/dev/null
grep -E 'softprops/action-gh-release@[0-9a-f]{40}' "$workflow" >/dev/null
if grep -F 'softprops/action-gh-release@v2' "$workflow" >/dev/null; then
	printf '%s\n' 'release action must be pinned to an immutable commit' >&2
	exit 1
fi

grep -F 'V: s' "$workflow" >/dev/null
grep -F 'name: Write build failure summary' "$workflow" >/dev/null
grep -F '>> "$GITHUB_STEP_SUMMARY"' "$workflow" >/dev/null
grep -F 'name: Upload build diagnostics' "$workflow" >/dev/null
grep -F 'if: failure()' "$workflow" >/dev/null
grep -F 'logs/**' "$workflow" >/dev/null

printf '%s\n' 'release workflow diagnostics test passed'
