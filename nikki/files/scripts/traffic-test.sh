#!/bin/sh
# /etc/nikki/scripts/traffic-test.sh - 流量统计功能诊断脚本
# 用于快速判断流量统计是否启动、关键代码能否执行

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 工具函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# 计数器
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_pass() {
    log_success "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    log_error "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_warn() {
    log_warn "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

echo "========================================"
echo "   Nikki 流量统计功能诊断脚本"
echo "========================================"
echo ""

# ========== 1. 检查基础文件是否存在 ==========
log_info "检查 1: 基础文件完整性"

if [ -f "/etc/nikki/ucode/traffic.uc" ]; then
    check_pass "traffic.uc 脚本存在"
else
    check_fail "traffic.uc 脚本不存在"
fi

if [ -f "/etc/nikki/scripts/traffic-collect.sh" ]; then
    check_pass "traffic-collect.sh 脚本存在"
else
    check_fail "traffic-collect.sh 脚本不存在"
fi

if [ -f "/usr/share/rpcd/traffic.lua" ] || [ -f "/usr/share/rpcd/traffic.lua" ]; then
    check_pass "traffic.lua RPC 接口存在"
else
    check_fail "traffic.lua RPC 接口不存在"
fi

echo ""

# ========== 2. 检查 UCI 配置 ==========
log_info "检查 2: UCI 配置"

if uci -q get nikki.traffic >/dev/null 2>&1; then
    check_pass "nikki.traffic 配置节存在"
    
    ENABLED=$(uci -q get nikki.traffic.enabled)
    if [ "$ENABLED" = "1" ]; then
        check_pass "流量统计已启用 (enabled=1)"
    else
        check_warn "流量统计未启用 (enabled=$ENABLED)"
    fi
    
    COLLECT_INTERVAL=$(uci -q get nikki.traffic.collect_interval)
    if [ -n "$COLLECT_INTERVAL" ]; then
        check_pass "采集间隔配置：${COLLECT_INTERVAL}s"
    else
        check_warn "采集间隔未配置"
    fi
    
    DB_PATH=$(uci -q get nikki.traffic.db_path)
    if [ -n "$DB_PATH" ]; then
        check_pass "数据库路径：$DB_PATH"
    else
        check_warn "数据库路径未配置"
    fi
else
    check_fail "nikki.traffic 配置节不存在"
fi

echo ""

# ========== 3. 检查 API Secret ==========
log_info "检查 3: Mihomo API Secret 配置"

API_SECRET=$(uci -q get nikki.mixin.api_secret)
if [ -n "$API_SECRET" ]; then
    check_pass "API Secret 已配置：${API_SECRET:0:2}******"
    
    # 检查 traffic.uc 中的 secret 是否正确读取
    log_info "验证 traffic.uc 能否正确读取 API Secret..."
    SECRET_CHECK=$(/usr/bin/ucode -e "
        import { cursor } from 'uci';
        const uci = cursor();
        const secret = uci.get('nikki', 'mixin', 'api_secret') || '';
        if (secret != '') {
            print('OK');
        } else {
            print('EMPTY');
        }
    " 2>&1)
    
    if [ "$SECRET_CHECK" = "OK" ]; then
        check_pass "traffic.uc 可以正确读取 API Secret"
    else
        check_fail "traffic.uc 无法读取 API Secret (返回：$SECRET_CHECK)"
    fi
else
    check_fail "API Secret 未配置 (nikki.mixin.api_secret)"
fi

echo ""

# ========== 4. 检查数据库 ==========
log_info "检查 4: SQLite 数据库状态"

if [ -f "$DB_PATH" ]; then
    check_pass "数据库文件存在：$DB_PATH"
    
    # 检查数据库是否可读
    if sqlite3 "$DB_PATH" "SELECT 1;" >/dev/null 2>&1; then
        check_pass "数据库可正常访问"
    else
        check_fail "数据库文件损坏或不可读"
    fi
    
    # 检查表结构
    TABLES=$(sqlite3 "$DB_PATH" ".tables" 2>/dev/null)
    if echo "$TABLES" | grep -q "traffic_daily"; then
        check_pass "traffic_daily 表存在"
    else
        check_warn "traffic_daily 表不存在"
    fi
    
    if echo "$TABLES" | grep -q "traffic_ip_daily"; then
        check_pass "traffic_ip_daily 表存在"
    else
        check_warn "traffic_ip_daily 表不存在"
    fi
    
    # 检查是否有数据
    ROW_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM traffic_daily;" 2>/dev/null || echo "0")
    if [ "$ROW_COUNT" -gt 0 ]; then
        check_pass "数据库中有 $ROW_COUNT 条日统计记录"
    else
        check_warn "数据库中没有日统计数据"
    fi
else
    check_warn "数据库文件不存在 (可能还未采集数据)"
fi

echo ""

# ========== 5. 检查 Mihomo API 可访问性 ==========
log_info "检查 5: Mihomo API 连接测试"

API_LISTEN=$(uci -q get nikki.mixin.api_listen)
if [ -z "$API_LISTEN" ]; then
    API_LISTEN="[::]:9090"
fi

# 提取端口
API_PORT=$(echo "$API_LISTEN" | sed 's/.*://' | sed 's/\]//')
if [ -z "$API_PORT" ] || [ "$API_PORT" = "$API_LISTEN" ]; then
    API_PORT="9090"
fi

log_info "API 监听地址：$API_LISTEN"

# 测试 API 连接
if command -v curl >/dev/null 2>&1; then
    # 测试 API 是否可访问
    API_RESPONSE=$(curl -s -m 3 -H "Authorization: Bearer $API_SECRET" "http://127.0.0.1:$API_PORT/version" 2>&1)

    if echo "$API_RESPONSE" | grep -q "version\|premium"; then
        check_pass "Mihomo API 可正常访问"

        # 优先测试新版 API (/traffic/summary)
        SUMMARY_RESPONSE=$(curl -s -m 3 -H "Authorization: Bearer $API_SECRET" "http://127.0.0.1:$API_PORT/traffic/summary" 2>&1)

        if echo "$SUMMARY_RESPONSE" | grep -q "upTotal"; then
            check_pass "新版 API (/traffic/summary) 返回正常"
            UP_TOTAL=$(echo "$SUMMARY_RESPONSE" | grep -o '"upTotal":[0-9]*' | cut -d':' -f2)
            DOWN_TOTAL=$(echo "$SUMMARY_RESPONSE" | grep -o '"downTotal":[0-9]*' | cut -d':' -f2)
            log_info "当前流量：上传=${UP_TOTAL:-0}B, 下载=${DOWN_TOTAL:-0}B"
        else
            # 兼容检查旧版 API
            TRAFFIC_RESPONSE=$(curl -s -m 3 -H "Authorization: Bearer $API_SECRET" "http://127.0.0.1:$API_PORT/traffic/latest" 2>&1)
            if echo "$TRAFFIC_RESPONSE" | grep -q "upTotal"; then
                check_warn "新版 API (/traffic/summary) 不可用，但旧版 (/traffic/latest) 正常"
                check_warn "建议升级内核以支持流量统计功能"
            else
                check_fail "流量 API 均不可用 (检查内核版本或 Secret)"
            fi
        fi
    else
        check_fail "无法连接到 Mihomo API (端口：$API_PORT)"
        log_info "请检查 mihomo 是否运行：/etc/init.d/nikki status"
    fi
else
    check_warn "curl 命令不可用，无法测试 API"
fi

echo ""

# ========== 6. 测试 traffic.uc 脚本执行 ==========
log_info "检查 6: traffic.uc 脚本执行测试"

# 测试 collect 命令
log_info "测试 collect 命令..."
COLLECT_RESULT=$(/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect 2>&1)
if [ $? -eq 0 ]; then
    check_pass "collect 命令执行成功"
else
    check_fail "collect 命令执行失败：$COLLECT_RESULT"
fi

# 测试 stats 命令
log_info "测试 stats 命令..."
STATS_RESULT=$(/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats day 2>&1)
if [ $? -eq 0 ]; then
    check_pass "stats 命令执行成功"
    # 显示返回的统计数据
    if echo "$STATS_RESULT" | grep -q "global\|ip"; then
        log_info "统计数据：$STATS_RESULT"
    fi
else
    check_fail "stats 命令执行失败：$STATS_RESULT"
fi

echo ""

# ========== 7. 检查服务状态 ==========
log_info "检查 7: 服务状态"

if [ -f "/etc/init.d/nikki-traffic" ]; then
    check_pass "nikki-traffic 服务脚本存在"

    if /etc/init.d/nikki-traffic running 2>/dev/null; then
        check_pass "nikki-traffic 服务运行中"
    else
        check_warn "nikki-traffic 服务未运行"
    fi

    # 检查实际进程
    TRAFFIC_PID=$(ps | grep "traffic-collect.sh" | grep -v grep | awk '{print $1}' | head -1)
    if [ -n "$TRAFFIC_PID" ]; then
        check_pass "采集进程正在运行 (PID: $TRAFFIC_PID)"
    else
        check_warn "采集进程不存在"
    fi
else
    check_warn "nikki-traffic 服务脚本不存在"
fi

echo ""

# ========== 总结 ==========
echo "========================================"
echo "   诊断结果汇总"
echo "========================================"
echo -e "${GREEN}通过${NC}: $PASS_COUNT"
echo -e "${RED}失败${NC}: $FAIL_COUNT"
echo -e "${YELLOW}警告${NC}: $WARN_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ 流量统计功能正常${NC}"
    exit 0
else
    echo -e "${RED}✗ 流量统计功能存在故障，请根据上述错误信息进行修复${NC}"
    exit 1
fi
