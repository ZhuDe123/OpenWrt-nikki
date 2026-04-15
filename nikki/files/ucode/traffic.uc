#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc - 完整流量统计脚本（高性能版）
// 支持：全局总量 + 各 IP 流量（活跃 + 已关闭）+ 按月统计

import { open, mkdir, chmod, stat, popen } from 'fs';

const DB_PATH = '/tmp/nikki/traffic.db';
const PERSIST_DB = '/etc/nikki/traffic.db.bak';
const API_SECRET = '163177';

// ========== 工具函数 ==========

function log(msg) {
    let t = popen("date '+%Y-%m-%d %H:%M:%S'");
    let timestamp = t ? trim(t.read('all')) : '';
    if (t) t.close();
    print(sprintf("[%s] [Traffic] %s\n", timestamp, msg));
}

function shell_quote(str) {
    return str ? "'" + replace(str, "'", "'\\''") + "'" : "''";
}

function get_api_url(path) {
    return sprintf("curl -s -H 'Authorization: Bearer %s' 'http://127.0.0.1:9090%s'", API_SECRET, path);
}

// ========== 数据库初始化 ==========

function init_db() {
    if (!stat('/tmp/nikki')) mkdir('/tmp/nikki', 0700);
    
    if (!stat(DB_PATH)) {
        let schema = `
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS traffic_monthly (month TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, ip));
            CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_daily(date);
            CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);
            CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);
        `;
        let p = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(schema)));
        if (p) p.close();
        chmod(DB_PATH, 0600);
    }
}

// ========== 数据采集（带锁） ==========

function collect_traffic() {
    init_db();
    
    // 检查是否已有采集在运行（防止并发）
    let lock_file = '/tmp/nikki/traffic.lock';
    if (stat(lock_file)) {
        log("Warning: Another collection is running, skipping");
        return;
    }
    
    // 创建锁文件
    let lock = open(lock_file, 'w');
    if (lock) {
        lock.write(time());
        lock.close();
    }
    
    try {
        // 1. 获取全局总量（非流式 API）
        let p1 = popen(get_api_url("/traffic/latest"));
        let traffic_res = p1 ? p1.read('all') : '{}';
        if (p1) p1.close();
        
        let traffic_data = {};
        if (traffic_res && match(traffic_res, /^\s*\{/)) {
            traffic_data = json(traffic_res) || {};
        }
        
        if (!traffic_data || !traffic_data.upTotal) {
            log("Warning: Cannot get traffic data");
            return;
        }
        
        let up_total = traffic_data.upTotal || 0;
        let down_total = traffic_data.downTotal || 0;
        
        // 2. 获取活跃连接的 IP 统计（限制数据量）
        let ip_stats = {};
        let p2 = popen(get_api_url("/connections") + " | head -c 50000");
        let conn_res = p2 ? p2.read('all') : '{}';
        if (p2) p2.close();
        
        let conn_data = {};
        if (conn_res && match(conn_res, /^\s*\{/)) {
            conn_data = json(conn_res) || {};
        }
        
        if (conn_data.connections) {
            for (let conn in conn_data.connections) {
                let ip = conn.metadata?.sourceIP || 'unknown';
                if (ip != 'unknown' && ip != 'invalid IP') {
                    if (!ip_stats[ip]) ip_stats[ip] = {up: 0, down: 0};
                    ip_stats[ip].up += (conn.upload || 0);
                    ip_stats[ip].down += (conn.download || 0);
                }
            }
        }
        
        // 3. 获取已关闭连接的 IP 统计
        let p3 = popen(get_api_url("/traffic/closed") + " | head -c 50000");
        let closed_res = p3 ? p3.read('all') : '{}';
        if (p3) p3.close();
        
        let closed_data = {};
        if (closed_res && match(closed_res, /^\s*\{/)) {
            closed_data = json(closed_res) || {};
        }
        
        if (closed_data.closedConnections) {
            for (let closed in closed_data.closedConnections) {
                let ip = closed.sourceIP;
                if (ip != 'unknown' && ip != 'invalid IP') {
                    if (!ip_stats[ip]) ip_stats[ip] = {up: 0, down: 0};
                    ip_stats[ip].up += (closed.upload || 0);
                    ip_stats[ip].down += (closed.download || 0);
                }
            }
        }
        
        // 4. 写入数据库
        let now = time();
        let today_p = popen("date +%Y-%m-%d");
        let today_str = today_p ? trim(today_p.read('all')) : '';
        if (today_p) today_p.close();
        
        let month_p = popen("date +%Y-%m");
        let month_str = month_p ? trim(month_p.read('all')) : '';
        if (month_p) month_p.close();
        
        // 写入全局总量（日）
        let sql_daily = sprintf(
            "INSERT INTO traffic_daily VALUES ('%s', %d, %d, %d) ON CONFLICT(date) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;",
            today_str, up_total, down_total, now, up_total, down_total, now
        );
        let p4 = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_daily)));
        if (p4) p4.close();
        
        // 写入全局总量（月）
        let sql_monthly = sprintf(
            "INSERT INTO traffic_monthly VALUES ('%s', %d, %d, %d) ON CONFLICT(month) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;",
            month_str, up_total, down_total, now, up_total, down_total, now
        );
        let p5 = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_monthly)));
        if (p5) p5.close();
        
        // 写入 IP 统计
        for (let ip, s in ip_stats) {
            let sql_ip = sprintf(
                "INSERT INTO traffic_ip_daily VALUES ('%s', '%s', %d, %d) ON CONFLICT(date, ip) DO UPDATE SET upload=upload+%d, download=download+%d;",
                today_str, ip, s.up, s.down, s.up, s.down
            );
            let p6 = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_ip)));
            if (p6) p6.close();
        }
        
        log(sprintf("Collected: Total(up=%d, down=%d), IPs=%d", up_total, down_total, length(ip_stats)));
        
    } finally {
        // 释放锁
        if (stat(lock_file)) {
            system("rm -f " + lock_file);
        }
    }
}

// ========== 数据持久化 ==========

function persist() {
    if (!stat(DB_PATH)) {
        log("No database to backup");
        return;
    }
    
    log("Starting backup...");
    mkdir('/etc/nikki', 0755);
    let cmd = sprintf("sqlite3 %s '.backup %s'", shell_quote(DB_PATH), shell_quote(PERSIST_DB));
    let ret = popen(cmd);
    if (ret) ret.close();
    chmod(PERSIST_DB, 0600);
    log("Backup completed");
}

// ========== 数据查询 ==========

function query_stats(period, date_val) {
    if (!date_val) {
        if (period == 'month') {
            date_val = strftime('%Y-%m', time());
        } else {
            date_val = strftime('%Y-%m-%d', time());
        }
    }
    
    let db_cmd = sprintf("sqlite3 -json %s ", shell_quote(DB_PATH));
    let res = { global: [], ip: [] };
    
    if (period == 'day') {
        let p1 = popen(db_cmd + shell_quote(sprintf(
            "SELECT date, upload, download, updated_at FROM traffic_daily WHERE date = '%s';", date_val
        )));
        if (p1) { res.global = json(p1.read('all')) || []; p1.close(); }
        
        let p2 = popen(db_cmd + shell_quote(sprintf(
            "SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 50;", date_val
        )));
        if (p2) { res.ip = json(p2.read('all')) || []; p2.close(); }
        
    } else if (period == 'month') {
        let month_val = substr(date_val, 0, 7);
        
        let p1 = popen(db_cmd + shell_quote(sprintf(
            "SELECT month, upload, download, updated_at FROM traffic_monthly WHERE month = '%s';", month_val
        )));
        if (p1) { res.global = json(p1.read('all')) || []; p1.close(); }
        
        // 按月聚合 IP 数据
        let p2 = popen(db_cmd + shell_quote(sprintf(
            "SELECT ip, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_daily WHERE date LIKE '%s%%' GROUP BY ip ORDER BY (upload+download) DESC LIMIT 50;", month_val
        )));
        if (p2) { res.ip = json(p2.read('all')) || []; p2.close(); }
    }
    
    print(json(res));
}

// 查询历史统计
function query_history(days) {
    if (!days || days < 1) days = 7;
    
    let db_cmd = sprintf("sqlite3 -json %s ", shell_quote(DB_PATH));
    let res = { daily: [], monthly: [], top_ip: [] };
    
    // 最近 N 天的日统计
    let p1 = popen(db_cmd + shell_quote(sprintf(
        "SELECT date, upload, download FROM traffic_daily WHERE date >= date('now', '-%d days') ORDER BY date DESC;", days
    )));
    if (p1) { res.daily = json(p1.read('all')) || []; p1.close(); }
    
    // 最近 N 个月的月统计
    let p2 = popen(db_cmd + shell_quote(sprintf(
        "SELECT month, upload, download FROM traffic_monthly WHERE month >= strftime('%%Y-%%m', date('now', '-%d months')) ORDER BY month DESC;", days
    )));
    if (p2) { res.monthly = json(p2.read('all')) || []; p2.close(); }
    
    // 今日 Top IP
    let today = strftime('%Y-%m-%d', time());
    let p3 = popen(db_cmd + shell_quote(sprintf(
        "SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 10;", today
    )));
    if (p3) { res.top_ip = json(p3.read('all')) || []; p3.close(); }
    
    print(json(res));
}

// ========== 清理旧数据 ==========

function cleanup(retain_days) {
    if (!retain_days) retain_days = 30;
    
    log(sprintf("Cleaning up data older than %d days...", retain_days));
    
    let sql = sprintf("DELETE FROM traffic_daily WHERE date < date('now', '-%d days');", retain_days);
    let p = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql)));
    if (p) p.close();
    
    log("Cleanup completed");
}

// ========== CLI 入口 ==========

let action = ARGV[0];

if (action == 'collect') {
    collect_traffic();
} else if (action == 'persist') {
    persist();
} else if (action == 'stats') {
    query_stats(ARGV[1], ARGV[2]);
} else if (action == 'history') {
    query_history(int(ARGV[1]) || 7);
} else if (action == 'cleanup') {
    cleanup(int(ARGV[1]) || 30);
} else {
    print('Usage: traffic.uc <command> [args...]\n');
    print('Commands:\n');
    print('  collect          - 采集当前流量数据\n');
    print('  persist          - 备份数据库到 flash\n');
    print('  stats [period] [date]  - 查询统计数据 (period: day|month)\n');
    print('  history [days]   - 查询历史统计 (默认 7 天)\n');
    print('  cleanup [days]   - 清理旧数据 (默认 30 天)\n');
}
