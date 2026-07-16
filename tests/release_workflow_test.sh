#!/bin/sh

set -eu

workflow=.github/workflows/release.yml
build_job="$(sed -n '/^  build:/,/^  release:/p' "$workflow")"

printf '%s\n' "$build_job" | grep -F 'path: luci-app-tailscale' >/dev/null
printf '%s\n' "$build_job" | grep -F 'if [[ -d logs ]]; then' >/dev/null

grep -F 'V: s' "$workflow" >/dev/null
grep -F 'name: Write build failure summary' "$workflow" >/dev/null
grep -F '>> "$GITHUB_STEP_SUMMARY"' "$workflow" >/dev/null
grep -F 'name: Upload build diagnostics' "$workflow" >/dev/null
grep -F 'if: failure()' "$workflow" >/dev/null
grep -F 'logs/**' "$workflow" >/dev/null

printf '%s\n' 'release workflow diagnostics test passed'
