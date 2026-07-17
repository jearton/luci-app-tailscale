# Final Review Fix Report

## Scope completed

All six final-review corrections were implemented as one fix wave:

1. Added an nftables table-generation guard before handle caching, made its deletion the first operation in the atomic reconciliation batch, and covered success, failure, signal, cleanup, and deterministic table-replacement paths.
2. Distinguished a verified absent UCI `enabled` option from UCI section/read failures.
3. Added `nft -j list tables` inventory checks so verified `inet fw4` absence remains non-fatal while inventory, table-read, and malformed-JSON failures remain errors.
4. Reordered cleanup to remove nftables rules before the hook, retained the hook when nftables cleanup failed, and made disabled status report managed residue.
5. Bumped `PKG_VERSION` to `1.2.8`.
6. Made status require the canonical managed hook body and exact structured nftables rule expressions while allowing dynamic counter values.

## Strict TDD evidence

Temporary test paths in two failure messages are normalized as `<tmp>`; all other output is verbatim.

### Correction 1: table-generation guard

- RED command: `sh tests/tailscale_openclash_bypass_test.sh`
- RED result: exit 1, `FAIL: apply must create a named counter before caching owned handles`
- GREEN command: `sh tests/tailscale_openclash_bypass_test.sh`
- GREEN result: exit 0, `tailscale OpenClash bypass tests passed`

### Correction 2: UCI absence versus failure

- RED command: `sh tests/tailscale_openclash_bypass_test.sh`
- RED result: exit 1, `FAIL: <tmp>/uci.log expected 1 exact occurrences of -q show tailscale_openclash.settings, got 0`
- GREEN command: `sh tests/tailscale_openclash_bypass_test.sh`
- GREEN result: exit 0, `tailscale OpenClash bypass tests passed`

### Correction 3: nftables table inventory

- RED command: `sh tests/tailscale_openclash_bypass_test.sh`
- RED result: exit 1, `FAIL: <tmp>/nft.calls expected 1 occurrences of -j list tables, got 0`
- GREEN command: `sh tests/tailscale_openclash_bypass_test.sh`
- GREEN result: exit 0, `tailscale OpenClash bypass tests passed`

### Correction 4: retryable cleanup and disabled residue

- RED command: `sh tests/tailscale_openclash_bypass_test.sh`
- RED result: exit 1, `FAIL: false alias 0 did not report disabled`
- GREEN command: `sh tests/tailscale_openclash_bypass_test.sh`
- GREEN result: exit 0, `tailscale OpenClash bypass tests passed`

### Correction 5: release version

- RED command: `sh tests/package_release_test.sh`
- RED result: exit 1, `FAIL: Makefile should contain: PKG_VERSION:=1.2.8`
- GREEN command: `sh tests/package_release_test.sh`
- GREEN result: exit 0, `package release tests passed`

### Correction 6: canonical status validation

- RED command: `sh -n tests/tailscale_openclash_bypass_test.sh && sh tests/tailscale_openclash_bypass_test.sh`
- RED result: exit 1, `FAIL: status accepted a noncanonical managed hook body`
- GREEN command: `sh -n root/usr/sbin/tailscale_openclash_bypass && sh tests/tailscale_openclash_bypass_test.sh`
- GREEN result: exit 0, `tailscale OpenClash bypass tests passed`

The complete 11-file shell suite and 4-file JavaScript suite also passed after each correction GREEN.

## Final verification

Focused checks:

```sh
sh -n root/usr/sbin/tailscale_openclash_bypass && \
sh -n tests/tailscale_openclash_bypass_test.sh && \
sh tests/tailscale_openclash_bypass_test.sh
sh -n tests/package_release_test.sh && sh tests/package_release_test.sh
```

Result: both passed.

Complete shell suite:

```sh
set -eu
count=0
for test_file in tests/*_test.sh; do
	sh "$test_file"
	count=$((count + 1))
done
printf 'shell test files passed: %s\n' "$count"
```

Result: `shell test files passed: 11`.

Complete JavaScript suite:

```sh
set -eu
count=0
for test_file in tests/*_test.js; do
	node "$test_file"
	count=$((count + 1))
done
printf 'JavaScript test files passed: %s\n' "$count"
```

Result: `JavaScript test files passed: 4`.

Static gates:

```sh
for file in .github/scripts/*.sh; do bash -n "$file"; done
for file in root/etc/init.d/tailscale root/etc/init.d/tailscale-openclash-bypass root/etc/hotplug.d/iface/* root/etc/uci-defaults/* root/usr/libexec/rpcd/* root/usr/sbin/tailscale_* tests/*_test.sh; do sh -n "$file"; done
for file in htdocs/luci-static/resources/view/tailscale/*.js tests/*_test.js; do node --check "$file"; done
for file in root/usr/share/luci/menu.d/*.json root/usr/share/rpcd/acl.d/*.json; do jq -e . "$file" >/dev/null; done
for file in po/templates/*.pot po/*/*.po; do msgfmt --check-format -o /dev/null "$file"; done
git diff --check
```

Results: 24 shell syntax files, 8 JavaScript syntax files, 2 JSON files, 3 translation files, and `git diff --check` passed.

Ownership-isolation searches returned no matches:

```sh
rg -n '/etc/config/firewall|uci (set|delete|commit) firewall|/etc/init.d/firewall|fw4 (reload|restart)' root/usr/sbin/tailscale_openclash_bypass root/etc/init.d/tailscale-openclash-bypass
rg -n 'tailscale_openclash_bypass|openclash_custom_firewall_rules' root/usr/sbin/tailscale_helper root/etc/init.d/tailscale
rg -n '/etc/init.d/openclash (start|stop|restart|reload|enable|disable)' root/usr/sbin/tailscale_openclash_bypass root/etc/init.d/tailscale-openclash-bypass
```

No Docker, MkDocs, router, remote-server, GitHub, or network command was used.

## Files changed

- `Makefile`
- `root/usr/sbin/tailscale_openclash_bypass`
- `tests/package_release_test.sh`
- `tests/tailscale_openclash_bypass_test.sh`
- `.superpowers/sdd/final-review-fix-report.md`

The pre-existing modifications to task-1 through task-4 reports were preserved byte-for-byte relative to their initial working-tree diff and excluded from staging.

## Self-review

- Reviewed the complete production and test diff against all six required corrections.
- Confirmed the generation-replacement fake preserves unrelated rules that reuse stale handles.
- Confirmed guard cleanup paths cover success, batch failure, signal exit, no-op cleanup, and table replacement.
- Confirmed status rejects noncanonical hooks, altered/overbroad/incomplete/wrong-chain rules, duplicate rules, and unexpected package-owned rules while accepting changing counter values.
- Confirmed cleanup failure leaves the hook retryable and disabled status reports both hook and rule residue.
- Confirmed only the five files listed above belong to this fix wave.

## Remaining concerns

None.
