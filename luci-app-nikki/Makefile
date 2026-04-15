include $(TOPDIR)/rules.mk

PKG_VERSION:=1.25.0

LUCI_TITLE:=LuCI Support for nikki
LUCI_DEPENDS:=+luci-base +nikki +libsqlite3 +curl

# 只包含简体中文和其他必要语言
LUCI_LANG:=zh_Hans

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature