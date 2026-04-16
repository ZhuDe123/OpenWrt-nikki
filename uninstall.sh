#!/bin/sh

# Nikki 卸载脚本 - 清理所有相关文件

echo "========================================"
echo "   Nikki 卸载脚本"
echo "========================================"

# 停止服务
echo "[1/5] 停止服务..."
/etc/init.d/nikki stop 2>/dev/null
/etc/init.d/nikki-traffic stop 2>/dev/null

# 卸载软件包
echo "[2/5] 卸载软件包..."
if [ -x "/bin/opkg" ]; then
    opkg list-installed luci-i18n-nikki-* | cut -d ' ' -f 1 | xargs opkg remove 2>/dev/null
    opkg remove luci-app-nikki 2>/dev/null
    opkg remove nikki 2>/dev/null
elif [ -x "/usr/bin/apk" ]; then
    apk list --installed --manifest luci-i18n-nikki-* | cut -d ' ' -f 1 | xargs apk del 2>/dev/null
    apk del luci-app-nikki 2>/dev/null
    apk del nikki 2>/dev/null
fi

# 删除配置文件
echo "[3/5] 删除配置文件..."
rm -f /etc/config/nikki

# 删除程序文件和数据
echo "[4/5] 删除程序文件和临时数据..."
rm -rf /etc/nikki                          # 主配置目录
rm -rf /var/log/nikki                      # 日志目录
rm -rf /var/run/nikki                      # 运行时目录
rm -rf /tmp/nikki                          # 临时文件目录（流量统计数据库）
rm -f /var/run/nikki.pid                   # 主进程 PID 文件
rm -f /var/run/nikki-traffic.pid           # 流量统计 PID 文件

# 清理防火墙和路由规则残留
echo "[5/5] 清理残留规则..."
nft delete table inet nikki 2>/dev/null
ip -4 rule del pref 1024 2>/dev/null
ip -6 rule del pref 1024 2>/dev/null
ip -4 rule del pref 1025 2>/dev/null
ip -6 rule del pref 1025 2>/dev/null
ip -4 route flush table 80 2>/dev/null
ip -6 route flush table 80 2>/dev/null
ip -4 route flush table 81 2>/dev/null
ip -6 route flush table 81 2>/dev/null

# 移除 feed
if [ -x "/bin/opkg" ]; then
    if grep -q nikki /etc/opkg/customfeeds.conf; then
        sed -i '/nikki/d' /etc/opkg/customfeeds.conf
    fi
    wget -q -O "nikki.pub" "https://nikkinikki.pages.dev/key-build.pub" 2>/dev/null
    opkg-key remove nikki.pub 2>/dev/null
    rm -f nikki.pub
elif [ -x "/usr/bin/apk" ]; then
    if grep -q nikki /etc/apk/repositories.d/customfeeds.list; then
        sed -i '/nikki/d' /etc/apk/repositories.d/customfeeds.list
    fi
    rm -f /etc/apk/keys/nikki.pem
fi

# 清理 LuCI 缓存
rm -rf /tmp/luci-*
/etc/init.d/rpcd restart 2>/dev/null

echo ""
echo "========================================"
echo "   卸载完成！"
echo "========================================"
echo ""
echo "注意："
echo "- 所有配置已删除"
echo "- 所有临时文件和日志已清理"
echo "- 防火墙规则已清除"
echo ""
