#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc - 完整流量统计脚本（使用 /traffic/ip API）
// 支持：全局总量 + 各 IP 流量（活跃 + 已关闭）+ 按月统计

import { open, mkdir, chmod, stat, popen } from 'fs';
import { cursor } from 'uci';

const DB_PATH = '/tmp/nikki/traffic.db';
const PERSIST_DB = '/etc/nikki/traffic.db.bak';

const uci = cursor();
const API_SECRET = uci.get('nikki', 'mixin', 'api_secret') || '';

// ========== 工具函数 ==========

function log(msg) {
    let t = popen("date '+%Y-%m-%d %H:%M:%S'");
    let timestamp = t ? trim(t.read('all')) : '';
    if (t) t.close();
    // 只在出错时才输出日志，减少日志量
    if (match(msg, /Error|Warning|Fail/)) {
        print(sprintf("[%s] [Traffic] %s\n", timestamp, msg));
    }
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

    // 检查数据库是否需要初始化（文件不存在或没有表）
    let need_init = false;
    if (!stat(DB_PATH)) {
        need_init = true;
    } else {
        // 检查表是否存在
        let check_p = popen(sprintf("sqlite3 %s '.tables' 2>/dev/null", shell_quote(DB_PATH)));
        if (check_p) {
            let tables = check_p.read('all') || '';
            check_p.close();
            if (!match(tables, /traffic_daily/) || !match(tables, /traffic_ip_daily/)) {
                need_init = true;
            }
        } else {
            need_init = true;
        }
    }
    
    if (need_init) {
        // 单条执行 SQL 语句
        popen(sprintf("sqlite3 %s 'PRAGMA journal_mode=WAL;'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_monthly (month TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_yearly (year TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, ip));'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_minute (date TEXT, time TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, time));'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_daily(date);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", shell_quote(DB_PATH)))?.close();
        popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", shell_quote(DB_PATH)))?.close();
        chmod(DB_PATH, 0600);
        log("Database initialized");
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
    
    // 定义释放锁的函数
    function release_lock() {
        if (stat(lock_file)) {
            system("rm -f " + lock_file);
        }
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
            release_lock();
            return;
        }

        let up_total = traffic_data.upTotal || 0;
        let down_total = traffic_data.downTotal || 0;

        // 2. 获取活跃连接的 IP 统计（使用新的聚合 API，无需限制 50KB）
        let ip_stats = {};
        let p2 = popen(get_api_url("/traffic/ip"));
        let ip_res = p2 ? p2.read('all') : '{}';
        if (p2) p2.close();

        // 解析 IP 统计数据
        let ip_data = {};
        if (ip_res && match(ip_res, /^\s*\{/)) {
            ip_data = json(ip_res) || {};
        }

        if (ip_data.ipStats) {
            for (let ip_stat in ip_data.ipStats) {
                let ip = ip_stat.ip;
                if (ip != 'unknown' && ip != 'invalid IP') {
                    if (!ip_stats[ip]) ip_stats[ip] = {up: 0, down: 0};
                    ip_stats[ip].up += (ip_stat.upload || 0);
                    ip_stats[ip].down += (ip_stat.download || 0);
                }
            }
        }

        // 3. 获取已关闭连接的 IP 统计
        let p3 = popen(get_api_url("/traffic/closed"));
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
        
        let time_p = popen("date +%H:%M");
        let time_str = time_p ? trim(time_p.read('all')) : '';
        if (time_p) time_p.close();

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
        
        // 写入年度总量
        let year_str = substr(month_str, 0, 4);
        let sql_yearly = sprintf(
            "INSERT INTO traffic_yearly VALUES ('%s', %d, %d, %d) ON CONFLICT(year) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;",
            year_str, up_total, down_total, now, up_total, down_total, now
        );
        let p_year = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_yearly)));
        if (p_year) p_year.close();
        
        // 写入分钟级数据
        let sql_minute = sprintf(
            "INSERT INTO traffic_minute VALUES ('%s', '%s', %d, %d) ON CONFLICT(date, time) DO UPDATE SET upload=%d, download=%d;",
            today_str, time_str, up_total, down_total, up_total, down_total
        );
        let p6 = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_minute)));
        if (p6) p6.close();

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

    } catch (e) {
        log("Error during collection: " + e);
    }
    
    // 每天清理一次旧数据
    let now_ts = time();
    let last_cleanup_str = uci.get('nikki', 'traffic', 'last_cleanup') || '0';
    let last_cleanup = int(last_cleanup_str) || 0;
    
    // 如果超过 24 小时，执行清理
    if ((now_ts - last_cleanup) > 86400) {
        let retain_days = int(uci.get('nikki', 'traffic', 'retain_days') || 30);
        
        // 直接执行清理逻辑（不使用 cleanup 函数）
        let sql_daily = sprintf("DELETE FROM traffic_daily WHERE date < date('now', '-%d days');", retain_days);
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_daily)))?.close();
        
        let sql_monthly = sprintf("DELETE FROM traffic_monthly WHERE month < strftime('%%Y-%%m', date('now', '-%d months'));", retain_days);
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_monthly)))?.close();
        
        let sql_ip = sprintf("DELETE FROM traffic_ip_daily WHERE date < date('now', '-%d days');", retain_days);
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_ip)))?.close();
        
        let sql_minute = sprintf("DELETE FROM traffic_minute WHERE date < date('now', '-1 day');");
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_minute)))?.close();
        
        uci.set('nikki', 'traffic', 'last_cleanup', sprintf('%d', now_ts));
        uci.commit('nikki');
        
        log("Cleaned up data older than " + retain_days + " days");
    }
    
    // 释放锁
    release_lock();
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

function query_stats(period, date_val, view_type) {
    if (!date_val) {
        // 使用 popen 获取当前日期
        let date_p = popen("date +%Y-%m-%d");
        let today = date_p ? trim(date_p.read('all')) : '';
        if (date_p) date_p.close();
        
        if (period == 'year') {
            date_val = strftime('%Y', time()) || popen("date +%Y")?.read('all') || '';
        } else if (period == 'month') {
            let month_p = popen("date +%Y-%m");
            date_val = month_p ? trim(month_p.read('all')) : '';
            if (month_p) month_p.close();
        } else {
            date_val = today;
        }
    }
    
    // 获取当前时间用于过滤
    let now_time = '';
    if (period == 'day') {
        now_time = popen("date +%H:%M")?.read('all') || '00:00';
        now_time = trim(now_time);
    }

    // 使用 shell 直接执行 sqlite3 并返回 JSON
    if (period == 'year') {
        // 年度视图：查询 12 个月的流量
        let monthly_cmd = sprintf("sqlite3 -json %s \"SELECT month, upload, download FROM traffic_monthly WHERE month LIKE '%s-%%' ORDER BY month;\"", 
            shell_quote(DB_PATH), date_val);
        let monthly_p = popen(monthly_cmd);
        let monthly_json = '[]';
        if (monthly_p) {
            monthly_json = monthly_p.read('all') || '[]';
            monthly_p.close();
        }
        
        // 查询年度总计
        let yearly_cmd = sprintf("sqlite3 -json %s \"SELECT year, upload, download FROM traffic_yearly WHERE year = '%s';\"", 
            shell_quote(DB_PATH), date_val);
        let yearly_p = popen(yearly_cmd);
        let yearly_json = '[]';
        if (yearly_p) {
            yearly_json = yearly_p.read('all') || '[]';
            yearly_p.close();
        }
        
        return sprintf('{"monthly":%s,"yearly":%s}', monthly_json, yearly_json);
        
    } else if (period == 'month') {
        // 月份视图：查询每天的流量
        let daily_cmd = sprintf("sqlite3 -json %s \"SELECT date, upload, download FROM traffic_daily WHERE date LIKE '%s-%%' ORDER BY date;\"", 
            shell_quote(DB_PATH), date_val);
        let daily_p = popen(daily_cmd);
        let daily_json = '[]';
        if (daily_p) {
            daily_json = daily_p.read('all') || '[]';
            daily_p.close();
        }
        
        // 查询月总计
        let monthly_cmd = sprintf("sqlite3 -json %s \"SELECT month, upload, download FROM traffic_monthly WHERE month = '%s';\"", 
            shell_quote(DB_PATH), date_val);
        let monthly_p = popen(monthly_cmd);
        let monthly_json = '[]';
        if (monthly_p) {
            monthly_json = monthly_p.read('all') || '[]';
            monthly_p.close();
        }
        
        return sprintf('{"daily":%s,"monthly":%s}', daily_json, monthly_json);
        
    } else if (period == 'day') {
        // 日视图：查询分钟级数据（从 00:00 到当前时间）
        let minute_cmd = sprintf("sqlite3 -json %s \"SELECT time, upload, download FROM traffic_minute WHERE date = '%s' AND time <= '%s' ORDER BY time;\"", 
            shell_quote(DB_PATH), date_val, now_time);
        let minute_p = popen(minute_cmd);
        let minute_json = '[]';
        if (minute_p) {
            minute_json = minute_p.read('all') || '[]';
            minute_p.close();
        }
        
        // 查询日统计
        let global_cmd = sprintf("sqlite3 -json %s \"SELECT date, upload, download, updated_at FROM traffic_daily WHERE date = '%s';\"", 
            shell_quote(DB_PATH), date_val);
        let global_p = popen(global_cmd);
        let global_json = '[]';
        if (global_p) {
            global_json = global_p.read('all') || '[]';
            global_p.close();
        }
        
        // 查询 IP 统计
        let ip_cmd = sprintf("sqlite3 -json %s \"SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 50;\"", 
            shell_quote(DB_PATH), date_val);
        let ip_p = popen(ip_cmd);
        let ip_json = '[]';
        if (ip_p) {
            ip_json = ip_p.read('all') || '[]';
            ip_p.close();
        }
        
        // 返回分钟级数据
        return sprintf('{"minute":%s,"global":%s,"ip":%s}', minute_json, global_json, ip_json);
    }
    
    return '{"minute":[],"global":[],"ip":[]}';
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

    let today = strftime('%Y-%m-%d', time());
    let current_month = strftime('%Y-%m', time());
    let current_year = strftime('%Y', time());
    
    // 清理旧的日统计数据
    let sql_daily = sprintf("DELETE FROM traffic_daily WHERE date < date('now', '-%d days');", retain_days);
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_daily)))?.close();
    
    // 清理旧的月统计数据（保留 retain_days 个月）
    let sql_monthly = sprintf("DELETE FROM traffic_monthly WHERE month < strftime('%%Y-%%m', date('now', '-%d months'));", retain_days);
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_monthly)))?.close();
    
    // 清理旧的年统计数据（保留 retain_days 年）
    let sql_yearly = sprintf("DELETE FROM traffic_yearly WHERE year < strftime('%%Y', date('now', '-%d years'));", retain_days);
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_yearly)))?.close();
    
    // 清理旧的 IP 统计数据
    let sql_ip = sprintf("DELETE FROM traffic_ip_daily WHERE date < date('now', '-%d days');", retain_days);
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_ip)))?.close();
    
    // 清理旧的分钟数据（只保留当天）
    let sql_minute = sprintf("DELETE FROM traffic_minute WHERE date < date('now', '-1 day');");
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_minute)))?.close();
    
    // 清理孤立的分钟数据（不属于当天的）
    let sql_minute_orphan = sprintf("DELETE FROM traffic_minute WHERE date != date('now');");
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_minute_orphan)))?.close();
    
    log(sprintf("Cleaned up data older than %d days", retain_days));
}

// ========== CLI 入口 ==========

let action = ARGV[0];

if (action == 'collect') {
    collect_traffic();
} else if (action == 'persist') {
    persist();
} else if (action == 'stats') {
    let result = query_stats(ARGV[1], ARGV[2], ARGV[3]);
    print(result);
} else if (action == 'history') {
    query_history(int(ARGV[1]) || 7);
} else if (action == 'cleanup') {
    cleanup(int(ARGV[1]) || 30);
} else {
    print('Usage: traffic.uc <command> [args...]\n');
    print('Commands:\n');
    print('  collect                      - 采集当前流量数据\n');
    print('  persist                      - 备份数据库到 flash\n');
    print('  stats [period] [date]        - 查询统计数据\n');
    print('    period: day|month|year     - 日/月/年视图\n');
    print('    date: 2026-04-16 | 2026-04 | 2026\n');
    print('  history [days]               - 查询历史统计 (默认 7 天)\n');
    print('  cleanup [days]               - 清理旧数据 (默认 30 天)\n');
}
