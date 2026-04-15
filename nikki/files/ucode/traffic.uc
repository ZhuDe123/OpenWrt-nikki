#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc

#!/bin/sh
# /usr/bin/traffic-collect - 使用 shell + sqlite3 实现

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
    local current_up=$(echo "$stats" | awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"uploadTotal"/){print $(i+1)}}}' | tr -d ' ')
    local current_down=$(echo "$stats" | awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"downloadTotal"/){print $(i+1)}}}' | tr -d ' ')
    
    # 获取上次状态
    local last_state=$(load_state)
    local last_up=$(echo "$last_state" | awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"uploadTotal"/){print $(i+1)}}}' | tr -d ' ')
    local last_down=$(echo "$last_state" | awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"downloadTotal"/){print $(i+1)}}}' | tr -d ' ')
    local last_timestamp=$(echo "$last_state" | awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"timestamp"/){print $(i+1)}}}' | tr -d ' ')
    
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
    
    # 处理 IP 统计（这里简化处理，仅从连接信息提取IP并统计）
    # 实际实现中需要解析 connections 数组
    local connections=$(echo "$stats" | grep -o '"connections":\[[^]]*\]' | sed 's/"connections"://' | tr -d '[]')
    
    if [ -n "$connections" ]; then
        # 这里需要更复杂的 JSON 解析，暂时跳过
        # 可以使用 jq 工具来更好地解析 JSON
        :
    fi
    
    # 更新状态文件
    local new_state="{\"uploadTotal\": $current_up, \"downloadTotal\": $current_down, \"timestamp\": $now, \"last_cleanup\": $last_cleanup}"
    save_state "$new_state"
    
    # 清理旧数据（每天一次）
    local last_cleanup=$(echo "$last_state" | awk -F'[,:}]' '{for(i=1;i<=NF;i++){if($i ~ /"last_cleanup"/){print $(i+1)}}}' | tr -d ' ')
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
    *)
        echo "Usage: $0 {collect|stats|ip-stats} [period/date] [date/hour]"
        exit 1
        ;;
esac

function cleanup_old_data(db, today) {
    let retain_days = 30;
    let retain_date = strftime('%Y-%m-%d', time() - (retain_days * 86400));
    
    db:execute(`DELETE FROM traffic_daily WHERE date < '${retain_date}'`);
    db:execute(`DELETE FROM traffic_hourly WHERE datetime < '${retain_date}'`);
    db:execute(`DELETE FROM traffic_ip_stats WHERE date < '${retain_date}'`);
    
    // 清理 WAL 文件
    db:execute('PRAGMA wal_checkpoint(TRUNCATE)');
}

// ========== 数据查询 ==========

function get_stats(period, date) {
    let db = init_db();
    let result = [];
    
    if (period == 'day') {
        result = db:query(`
            SELECT datetime as time, upload, download, (upload + download) as total
            FROM traffic_hourly
            WHERE datetime LIKE '${date}%'
            ORDER BY datetime
        `);
    } else if (period == 'month') {
        result = db:query(`
            SELECT date as time, upload_total as upload, download_total as download, 
                   (upload_total + download_total) as total
            FROM traffic_daily
            WHERE date LIKE '${date}%'
            ORDER BY date
        `);
    } else if (period == 'year') {
        result = db:query(`
            SELECT strftime('%Y-%m', date) as time,
                   SUM(upload_total) as upload,
                   SUM(download_total) as download,
                   SUM(upload_total + download_total) as total
            FROM traffic_daily
            WHERE date LIKE '${date}%'
            GROUP BY strftime('%Y-%m', date)
            ORDER BY time
        `);
    }
    
    return result;
}

function get_ip_stats(date, hour) {
    let db = init_db();
    
    if (hour != null) {
        return db:query(`
            SELECT ip_address, upload, download, (upload + download) as total
            FROM traffic_ip_stats
            WHERE date = '${date}' AND hour = ${hour}
            ORDER BY total DESC
            LIMIT 100
        `);
    } else {
        return db:query(`
            SELECT ip_address, 
                   SUM(upload) as upload, 
                   SUM(download) as download,
                   SUM(upload + download) as total
            FROM traffic_ip_stats
            WHERE date = '${date}'
            GROUP BY ip_address
            ORDER BY total DESC
            LIMIT 100
        `);
    }
}

function get_today_total() {
    let db = init_db();
    let today = strftime('%Y-%m-%d', time());
    let result = db:query(`SELECT upload_total, download_total FROM traffic_daily WHERE date='${today}'`);
    return result[0] || { upload_total: 0, download_total: 0 };
}

// ========== 数据导出（关机备份用）==========

function export_data() {
    let db = init_db();
    let backup_path = '/etc/nikki/traffic.db.bak';
    
    mkdir('/etc/nikki');
    
    // 导出为 SQL 语句
    let f = open(backup_path, 'w');
    f:write('-- Nikki Traffic Backup\n');
    f:write(`-- Time: ${strftime('%Y-%m-%d %H:%M:%S', time())}\n\n`);
    
    for (let row in db:query('SELECT * FROM traffic_daily')) {
        f:write(`INSERT OR REPLACE INTO traffic_daily VALUES ('${row.date}', ${row.upload_total}, ${row.download_total}, ${row.updated_at});\n`);
    }
    
    for (let row in db:query('SELECT * FROM traffic_hourly')) {
        f:write(`INSERT OR REPLACE INTO traffic_hourly VALUES ('${row.datetime}', ${row.upload}, ${row.download}, ${row.updated_at});\n`);
    }
    
    for (let row in db:query('SELECT * FROM traffic_ip_stats')) {
        f:write(`INSERT OR REPLACE INTO traffic_ip_stats VALUES (${row.id}, '${row.date}', ${row.hour}, '${row.ip_address}', ${row.upload}, ${row.download});\n`);
    }
    
    f:close();
    
    return backup_path;
}

function import_data() {
    let backup_path = '/etc/nikki/traffic.db.bak';
    let f = open(backup_path, 'r');
    
    if (!f) {
        warn('No backup file found');
        return false;
    }
    
    let db = init_db();
    db:execute('BEGIN TRANSACTION');
    
    try {
        let content = f:read('all');
        f:close();
        
        for (let line in split(content, '\n')) {
            if (match(line, /^INSERT/)) {
                db:execute(line);
            }
        }
        
        db:execute('COMMIT');
        return true;
    } catch (e) {
        db:execute('ROLLBACK');
        warn(`Import error: ${e}`);
        return false;
    }
}

// ========== CLI 入口 ==========

let args = ARGV;
if (length(args) < 1) {
    print('Usage: traffic.uc <command> [args...]');
    print('Commands: collect, stats, ip-stats, export, import');
    exit(1);
}

let cmd = args[0];

if (cmd == 'collect') {
    collect_traffic();
    print('Traffic collected.');
} else if (cmd == 'stats') {
    let period = args[1] || 'day';
    let date = args[2] || strftime('%Y-%m-%d', time());
    print(json(get_stats(period, date), true));
} else if (cmd == 'ip-stats') {
    let date = args[1] || strftime('%Y-%m-%d', time());
    let hour = args[2] ? int(args[2]) : null;
    print(json(get_ip_stats(date, hour), true));
} else if (cmd == 'export') {
    let path = export_data();
    print(`Data exported to ${path}`);
} else if (cmd == 'import') {
    if (import_data()) {
        print('Data imported successfully.');
    } else {
        print('Import failed.');
        exit(1);
    }
} else {
    print(`Unknown command: ${cmd}`);
    exit(1);
}