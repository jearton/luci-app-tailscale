# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2024 asvow

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI for Tailscale
LUCI_DEPENDS:=+tailscale +jshn +curl +jq +flock
LUCI_PKGARCH:=all

PKG_VERSION:=1.2.10

define Package/luci-app-tailscale/conffiles
/etc/config/tailscale
/etc/config/tailscale_openclash
endef

define Package/luci-app-tailscale/prerm
#!/bin/sh
case "$${1:-}" in
	remove) ;;
	*) exit 0 ;;
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
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
