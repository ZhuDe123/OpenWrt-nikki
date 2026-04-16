#!/bin/sh
# /etc/nikki/scripts/traffic-cron.sh - 流量统计定时采集脚本

# 检查流量统计是否启用
ENABLED=$(uci -q get nikki.traffic.enabled)
[ "$ENABLED" != "1" ] && exit 0

# 执行采集
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect

# 每分钟执行一次备份
MINUTE=$(date +%M)
[ "$MINUTE" = "00" ] && /usr/bin/ucode /etc/nikki/ucode/traffic.uc persist
