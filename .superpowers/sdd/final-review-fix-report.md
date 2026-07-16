# Final Review Fix Report

## Summary of fixes

- Added stateful exit-node firewall reconciliation in `tailscale_helper`:
  - save the original `firewall.@defaults[0].forward` value before forcing `REJECT`
  - save the original LAN->WAN forwarding `enabled` override state
  - restore both on helper runs without `EXIT_NODE`
  - expose `--cleanup-exit-node-firewall` so init stop/reload can restore state before teardown
- Updated `root/etc/init.d/tailscale` to:
  - pass `TAILSCALE_HELPER_STATE_DIR` into the helper
  - invoke helper cleanup during `stop_instance()`
  - only apply AdGuard `down` when auto-switch is enabled or the managed `up` profile was previously applied
  - reuse `PROGD` instead of hardcoded `tailscaled` paths
- Updated `tailscale_keepalive` peer resolution to match `TailscaleIPs` in both jshn and python paths, including IP-only peers with no hostname or DNS name.
- Added regression coverage for:
  - exit-node firewall restore on non-exit-node helper runs
  - stop-path helper cleanup invocation
  - AdGuard disabled/enabled/managed-up lifecycle behavior
  - keepalive resolution by Tailnet IP

## Files changed

- `root/usr/sbin/tailscale_helper`
- `root/etc/init.d/tailscale`
- `root/usr/sbin/tailscale_keepalive`
- `tests/tailscale_helper_network_cleanup_test.sh`
- `tests/tailscale_keepalive_test.sh`
- `tests/tailscale_init_adguard_lifecycle_test.sh`

## Test commands/results

- `sh tests/tailscale_helper_network_cleanup_test.sh` — passed
- `sh tests/tailscale_keepalive_test.sh` — passed
- `sh tests/tailscale_init_adguard_lifecycle_test.sh` — passed
- `sh tests/package_release_test.sh` — passed
- `sh -n root/usr/sbin/tailscale_helper root/usr/sbin/tailscale_keepalive root/etc/init.d/tailscale` — passed
- `git diff --check` — passed

## Concerns

- None identified from the required verification set.
