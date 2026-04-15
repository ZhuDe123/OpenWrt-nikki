#!/bin/sh
# /etc/nikki/scripts/traffic-collect.sh - 使用 shell + sqlite3 实现

DB_PATH="/tmp/nikki/traffic.db"
STATE_FILE="/tmp/nikki/traffic_state.json"
MAX_IP_STATS=50
mkdir -p /tmp/nikki

# ========== 状态管理 ==========

load_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo '{"uploadTotal": 0, "downloadTotal": 0, "timestamp": 0, "last_cleanup": 0}'
    fi
}

save_state() {
    echo "$1" > "$STATE_FILE"
}

# ========== 数据库初始化 ==========

init_db() {
    sqlite3 "$DB_PATH" << EOF
PRAGMA journal_mode=WAL;
PRAGMA synchronous=OFF;
PRAGMA cache_size=4096;
PRAGMA temp_store=MEMORY;
PRAGMA mmap_size=268435456;

CREATE TABLE IF NOT EXISTS traffic_daily (
    date TEXT PRIMARY KEY,
    upload_total INTEGER DEFAULT 0,
    download_total INTEGER DEFAULT 0,
    updated_at INTEGER
);

CREATE TABLE IF NOT EXISTS traffic_hourly (
    datetime TEXT PRIMARY KEY,
    upload INTEGER DEFAULT 0,
    download INTEGER DEFAULT 0,
    updated_at INTEGER
);

CREATE TABLE IF NOT EXISTS traffic_ip_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,
    hour INTEGER NOT NULL,
    ip_address TEXT NOT NULL,
    upload INTEGER DEFAULT 0,
    download INTEGER DEFAULT 0,
    UNIQUE(date, hour, ip_address)
);

CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_stats(date, hour);
CREATE INDEX IF NOT EXISTS idx_hourly ON traffic_hourly(datetime);
EOF
}

# ========== 数据采集 ==========

get_traffic_stats() {
    # 尝试通过 nikki API 获取流量数据
    local api_response=$(curl -s -X GET "http://127.0.0.1:9090/traffic" 2>/dev/null)
    if [ -n "$api_response" ] && [ "$api_response" != "null" ]; then
        echo "$api_response"
        return 0
    fi
    
    # 如果 API 不可用，返回默认值
    echo '{"uploadTotal": 0, "downloadTotal": 0, "connections": []}'
}

calc_delta() {
    local current_up=$1
    local current_down=$2
    local last_up=$3
    local last_down=$4
    
    local up_delta=$((current_up - last_up))
    local down_delta=$((current_down - last_down))
    
    # 内核重启检测（累计值重置）
    if [ $up_delta -lt 0 ]; then up_delta=$current_up; fi
    if [ $down_delta -lt 0 ]; then down_delta=$current_down; fi
    
    echo "$up_delta $down_delta"
}

collect_traffic() {
    init_db
    
    # 获取当前流量统计
    local stats=$(get_traffic_stats)
    
    # 提取当前上传下载总量（需要更精确的JSON解析）
    local current_up=$(echo "$stats" | jsonfilter -e '@.uploadTotal')
    if [ -z "$current_up" ] || [ "$current_up" = "null" ]; then
        current_up=0
    fi
    
    local current_down=$(echo "$stats" | jsonfilter -e '@.downloadTotal')
    if [ -z "$current_down" ] || [ "$current_down" = "null" ]; then
        current_down=0
    fi
    
    # 获取上次状态
    local last_state=$(load_state)
    local last_up=$(echo "$last_state" | jsonfilter -e '@.uploadTotal')
    local last_down=$(echo "$last_state" | jsonfilter -e '@.downloadTotal')
    local last_timestamp=$(echo "$last_state" | jsonfilter -e '@.timestamp')
    
    # 时间戳
    local now=$(date +%s)
    
    # 时间回退检测
    if [ $now -lt $last_timestamp ]; then
        logger "Nikki traffic: Time rollback detected. Skipping collection."
        return
    fi
    
    # 计算增量
    local deltas=$(calc_delta $current_up $current_down $last_up $last_down)
    local delta_up=$(echo "$deltas" | awk '{print $1}')
    local delta_down=$(echo "$deltas" | awk '{print $2}')
    
    local today=$(date +%Y-%m-%d)
    local this_hour=$(date +"%Y-%m-%d %H:00")
    local current_hour=$(date +%H)
    
    # 开始事务
    sqlite3 "$DB_PATH" << EOF
BEGIN TRANSACTION;

-- 更新每日统计
INSERT OR REPLACE INTO traffic_daily (date, upload_total, download_total, updated_at)
VALUES ('$today', 
        COALESCE((SELECT upload_total FROM traffic_daily WHERE date='$today'), 0) + $delta_up,
        COALESCE((SELECT download_total FROM traffic_daily WHERE date='$today'), 0) + $delta_down,
        $now);

-- 更新每小时统计
INSERT OR REPLACE INTO traffic_hourly (datetime, upload, download, updated_at)
VALUES ('$this_hour',
        COALESCE((SELECT upload FROM traffic_hourly WHERE datetime='$this_hour'), 0) + $delta_up,
        COALESCE((SELECT download FROM traffic_hourly WHERE datetime='$this_hour'), 0) + $delta_down,
        $now);

COMMIT;
EOF
    
    # 更新状态文件
    local new_state="{\"uploadTotal\": $current_up, \"downloadTotal\": $current_down, \"timestamp\": $now, \"last_cleanup\": $last_cleanup}"
    save_state "$new_state"
    
    # 获取连接信息并统计IP流量
    local connections_json=$(echo "$stats" | jsonfilter -e '@.connections')
    if [ -n "$connections_json" ] && [ "$connections_json" != "null" ]; then
        # 使用临时文件处理JSON数组
        echo "$connections_json" > /tmp/conn_temp.json
        
        # 提取IP和流量信息
        local ip_stats_file="/tmp/ip_stats_temp.sql"
        > "$ip_stats_file"  # 清空文件
        
        # 遍历连接并累加每个IP的流量
        local count=$(echo "$connections_json" | jsonfilter -e '[@] | length()')
        local i=0
        while [ $i -lt $count ]; do
            local conn=$(echo "$connections_json" | jsonfilter -e "@[$i]")
            local ip=$(echo "$conn" | jsonfilter -e '@.metadata.sourceIP')
            if [ -n "$ip" ] && [ "$ip" != "null" ]; then
                local upload=$(echo "$conn" | jsonfilter -e '@.uploadTotal // @.upload // 0')
                local download=$(echo "$conn" | jsonfilter -e '@.downloadTotal // @.download // 0')
                
                if [ -n "$upload" ] && [ "$upload" != "null" ]; then
                    echo "INSERT OR REPLACE INTO traffic_ip_stats (date, hour, ip_address, upload, download) VALUES ('$today', $current_hour, '$ip', $upload, $download);" >> "$ip_stats_file"
                fi
            fi
            i=$((i + 1))
        done
        
        # 执行IP统计更新
        if [ -s "$ip_stats_file" ]; then
            sqlite3 "$DB_PATH" < "$ip_stats_file"
        fi
        
        rm -f /tmp/conn_temp.json "$ip_stats_file"
    fi
    
    # 清理旧数据（每天一次）
    local last_cleanup=$(echo "$last_state" | jsonfilter -e '@.last_cleanup')
    if [ -z "$last_cleanup" ]; then last_cleanup=0; fi
    
    if [ $((now - last_cleanup)) -gt 86400 ]; then
        cleanup_old_data "$today"
        local new_state="{\"uploadTotal\": $current_up, \"downloadTotal\": $current_down, \"timestamp\": $now, \"last_cleanup\": $now}"
        save_state "$new_state"
    fi
}

cleanup_old_data() {
    local today=$1
    local retain_days=30
    local retain_date=$(date -d "$retain_days days ago" +%Y-%m-%d)
    
    sqlite3 "$DB_PATH" << EOF
DELETE FROM traffic_daily WHERE date < '$retain_date';
DELETE FROM traffic_hourly WHERE datetime < '$retain_date';
DELETE FROM traffic_ip_stats WHERE date < '$retain_date';
PRAGMA wal_checkpoint(TRUNCATE);
EOF
}

# ========== 数据查询 ==========

get_stats() {
    local period=$1
    local date=$2
    local result=""
    
    case $period in
        "day")
            result=$(sqlite3 -json "$DB_PATH" "SELECT datetime as time, upload, download, (upload + download) as total FROM traffic_hourly WHERE datetime LIKE '$date%' ORDER BY datetime;")
            ;;
        "month")
            result=$(sqlite3 -json "$DB_PATH" "SELECT date as time, upload_total as upload, download_total as download, (upload_total + download_total) as total FROM traffic_daily WHERE date LIKE '$date%' ORDER BY date;")
            ;;
        "year")
            result=$(sqlite3 -json "$DB_PATH" "SELECT strftime('%Y-%m', date) as time, SUM(upload_total) as upload, SUM(download_total) as download, SUM(upload_total + download_total) as total FROM traffic_daily WHERE date LIKE '$date%' GROUP BY strftime('%Y-%m', date) ORDER BY time;")
            ;;
    esac
    
    echo "$result"
}

get_ip_stats() {
    local date=$1
    local hour=$2
    local result=""
    
    if [ -n "$hour" ]; then
        result=$(sqlite3 -json "$DB_PATH" "SELECT ip_address, upload, download, (upload + download) as total FROM traffic_ip_stats WHERE date = '$date' AND hour = $hour ORDER BY total DESC LIMIT 100;")
    else
        result=$(sqlite3 -json "$DB_PATH" "SELECT ip_address, SUM(upload) as upload, SUM(download) as download, SUM(upload + download) as total FROM traffic_ip_stats WHERE date = '$date' GROUP BY ip_address ORDER BY total DESC LIMIT 100;")
    fi
    
    echo "$result"
}

# ========== 主函数 ==========

case "$1" in
    "collect")
        collect_traffic
        echo "Traffic collected."
        ;;
    "stats")
        period=${2:-"day"}
        date=${3:-$(date +%Y-%m-%d)}
        get_stats "$period" "$date"
        ;;
    "ip-stats")
        date=${2:-$(date +%Y-%m-%d)}
        hour=$3
        get_ip_stats "$date" "$hour"
        ;;
    "export")
        # 导出数据用于备份
        cp "$DB_PATH" "/tmp/nikki/traffic.db.backup"
        echo "Data exported to /tmp/nikki/traffic.db.backup"
        ;;
    *)
        echo "Usage: $0 {collect|stats|ip-stats|export} [period/date] [date/hour]"
        exit 1
        ;;
esac