# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2024 asvow

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI for Tailscale
LUCI_DEPENDS:=+tailscale +jshn +curl +jq +flock
LUCI_PKGARCH:=all

PKG_VERSION:=1.2.14

# Keep UCI configs as ordinary package data. The pre-install hook snapshots an
# existing configuration before extraction; the UCI-defaults script restores it
# afterwards. Declaring the same files as opkg conffiles conflicts with this
# lifecycle and creates inactive *-opkg files during upgrades.
define Package/luci-app-tailscale/preinst
#!/bin/sh
state_dir=/etc/.luci-app-tailscale-upgrade
state_pending="$${state_dir}.pending"

[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -f /etc/config/tailscale ] || exit 0
[ -f "$${state_dir}/.complete" ] && exit 0

clear_state_dir() {
	rm -f "$${1}/tailscale" "$${1}/tailscale_openclash" \
		"$${1}/tailscale_openclash.absent" "$${1}/.complete"
	rmdir "$${1}" 2>/dev/null || [ ! -e "$${1}" ]
}

clear_state_dir "$${state_dir}" || exit 1
clear_state_dir "$${state_pending}" || exit 1
umask 077
mkdir "$${state_pending}" || exit 1
chmod 700 "$${state_pending}" || exit 1
cp /etc/config/tailscale "$${state_pending}/tailscale" || exit 1
if [ -f /etc/config/tailscale_openclash ]; then
	cp /etc/config/tailscale_openclash "$${state_pending}/tailscale_openclash" || exit 1
else
	: >"$${state_pending}/tailscale_openclash.absent" || exit 1
fi
: >"$${state_pending}/.complete" || exit 1
mv "$${state_pending}" "$${state_dir}" || exit 1
exit 0
endef

define Package/luci-app-tailscale/prerm
#!/bin/sh
state_dir=/etc/.luci-app-tailscale-upgrade

case "$${2:-}" in
	remove|[0-9]*) ;;
	*)
		# default_prerm sources this script for opkg, while OpenWrt 24.10
		# apk runs pre-deinstall directly with the old package version in $1.
		case "$${1:-}" in
			[0-9]*) ;;
			*) exit 0 ;;
		esac
		;;
esac

if [ -z "$${IPKG_INSTROOT}" ] && [ -x /usr/sbin/tailscale_openclash_bypass ]; then
	/usr/sbin/tailscale_openclash_bypass cleanup >/dev/null 2>&1 || true
fi
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/tailscale-openclash-bypass ]; then
	/etc/init.d/tailscale-openclash-bypass disable >/dev/null 2>&1 || true
fi
if [ -z "$${IPKG_INSTROOT}" ] && [ -x /etc/init.d/tailscale ]; then
	/etc/init.d/tailscale stop >/dev/null 2>&1 || exit 1
fi
for cleanup_dir in "$${state_dir}" "$${state_dir}.pending"; do
	rm -f "$${cleanup_dir}/tailscale" "$${cleanup_dir}/tailscale_openclash" \
		"$${cleanup_dir}/tailscale_openclash.absent" "$${cleanup_dir}/.complete"
	rmdir "$${cleanup_dir}" 2>/dev/null || true
done
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
