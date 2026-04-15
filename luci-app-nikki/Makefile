include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nikki
PKG_VERSION:=1.25.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for nikki
LUCI_DEPENDS:=+luci-base +nikki +ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-math +sqlite3-cli
LUCI_PKGARCH:=all

# 只包含简体中文和其他必要语言
LUCI_LANG:=zh_Hans

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
