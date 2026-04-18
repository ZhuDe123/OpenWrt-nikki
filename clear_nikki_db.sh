#!/bin/sh
# 清空 Nikki 流量统计数据脚本

echo "========================================"
echo "  Nikki 流量统计数据清理工具"
echo "========================================"
echo ""

# 1. 停止 Nikki 服务
echo "1. 停止 Nikki 服务..."
/etc/init.d/nikki stop
sleep 2

# 2. 清空数据库文件
echo "2. 清空流量统计数据库..."
rm -f /tmp/nikki/traffic.db
rm -f /tmp/nikki/traffic.db-shm
rm -f /tmp/nikki/traffic.db-wal
rm -f /tmp/nikki/traffic.db.init
rm -rf /etc/nikki/traffic.db.bak
echo "    数据库文件和备份文件已删除"

# 3. 清空流量统计日志（保留主服务日志）
echo ""
echo "3. 清空流量统计日志..."
rm -f /tmp/nikki/traffic.log
echo "    流量日志已清空"

# 4. 清理可能的锁文件
echo ""
echo "4. 清理锁文件..."
rm -f /tmp/nikki/traffic.lock
echo "    锁文件已清理"

# 5. 重启 Nikki 服务
echo ""
echo "5. 重启 Nikki 服务..."
/etc/init.d/nikki start
sleep 10  # 等待服务完全启动和数据库初始化

# 6. 检查服务状态
echo ""
echo "6. 检查服务状态..."
if /etc/init.d/nikki status > /dev/null 2>&1; then
    echo "    Nikki 服务运行正常"
else
    echo "    Nikki 服务启动失败，请检查日志"
    exit 1
fi

# 7. 验证数据库已重建
echo ""
echo "7. 验证数据库..."
if [ -f /tmp/nikki/traffic.db ]; then
    echo "    数据库已重建"
else
    echo "    数据库未创建，等待 10 秒..."
    sleep 10
    if [ -f /tmp/nikki/traffic.db ]; then
        echo "    数据库已创建"
    else
        echo "    警告：数据库未创建，请检查服务日志"
    fi
fi

# 8. 显示统计信息
echo ""
echo "========================================"
echo "  清理完成！"
echo "========================================"
echo ""
echo "已清空的数据:"
echo "  - 流量统计数据库 (/tmp/nikki/traffic.db)"
echo "  - 流量统计日志 (/tmp/nikki/traffic.log)"
echo "  - 数据库锁文件 (/tmp/nikki/traffic.lock)"
echo ""
echo "服务状态:"
/etc/init.d/nikki status
echo ""
echo "提示:"
echo "  - 服务将在 30 秒后开始采集新的流量数据"
echo "  - 刷新浏览器页面 (Ctrl+F5) 查看最新数据"
echo "  - 执行以下命令验证："
echo "    sqlite3 /tmp/nikki/traffic.db \"SELECT * FROM traffic_daily;\""
echo ""
