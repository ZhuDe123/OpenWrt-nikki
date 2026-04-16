#!/bin/sh
# /etc/nikki/scripts/traffic-collect.sh
# 流量统计采集脚本，由 procd 管理
# 参数 1: 采集间隔（秒）

COLLECT_INTERVAL=${1:-30}

while true; do
    /usr/bin/ucode /etc/nikki/ucode/traffic.uc collect
    sleep "$COLLECT_INTERVAL"
done
