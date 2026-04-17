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
    // 只在出错时才输出日志，减少日志量
    if (match(msg, /Error|Warning|Fail/)) {
        let t = localtime(time());
        let timestamp = sprintf('%d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
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

    // 使用标记文件避免每次采集都检查表结构
    let init_flag = '/tmp/nikki/traffic.db.init';
    if (stat(init_flag)) return;  // 已初始化，直接返回

    // 数据库不存在或首次初始化
    popen(sprintf("sqlite3 %s 'PRAGMA journal_mode=WAL;'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_monthly (month TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_yearly (year TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, ip));'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_minute (date TEXT, time TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, time));'", shell_quote(DB_PATH)))?.close();
    // 新增：存储上次采集的累计总量
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_last_capture (key TEXT PRIMARY KEY, upload INTEGER, download INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", shell_quote(DB_PATH)))?.close();
    chmod(DB_PATH, 0600);

    // 创建标记文件
    let flag = open(init_flag, 'w');
    if (flag) {
        flag.write('1');
        flag.close();
    }

    log("Database initialized");
}

// ========== 数据采集（带锁） ==========

function collect_traffic() {
    init_db();

    // 检查是否已有采集在运行（使用 PID 验证，避免残留锁文件）
    let lock_file = '/tmp/nikki/traffic.lock';
    if (stat(lock_file)) {
        let lock_p = open(lock_file, 'r');
        if (lock_p) {
            let lock_pid = trim(lock_p.read('all') || '');
            lock_p.close();
            // 检查进程是否仍在运行
            if (lock_pid && stat('/proc/' + lock_pid)) {
                log("Warning: Another collection is running (PID " + lock_pid + "), skipping");
                return;
            }
            // 进程已不存在，清理残留锁文件
            system("rm -f " + lock_file);
        }
    }

    // 创建锁文件（写入当前进程 PID）
    let my_pid = popen("cat /proc/self/stat 2>/dev/null | cut -d' ' -f1");
    let pid_str = my_pid ? trim(my_pid.read('all')) : '';
    if (my_pid) my_pid.close();

    let lock = open(lock_file, 'w');
    if (lock) {
        lock.write(pid_str || '0');
        lock.close();
    }

    // 定义释放锁的函数
    function release_lock() {
        system("rm -f " + lock_file);
    }

    try {
        // 1. 获取全局总量 + IP 统计（单次 API 调用，替代原来的 3 次）
        let p1 = popen(get_api_url("/traffic/summary"));
        let summary_res = p1 ? p1.read('all') : '{}';
        if (p1) p1.close();

        let summary_data = {};
        if (summary_res && match(summary_res, /^\s*\{/)) {
            summary_data = json(summary_res) || {};
        }

        if (!summary_data || !summary_data.upTotal) {
            log("Warning: Cannot get traffic data from /traffic/summary");
            release_lock();
            return;
        }

        let up_total = summary_data.upTotal || 0;
        let down_total = summary_data.downTotal || 0;

        // 2. 解析 IP 统计数据（summary 接口已包含所有 IP）
        let ip_stats = {};
        if (summary_data.ipStats) {
            for (let ip_stat in summary_data.ipStats) {
                let ip = ip_stat.ip;
                if (ip && ip != 'unknown' && ip != 'invalid IP') {
                    if (!ip_stats[ip]) ip_stats[ip] = {up: 0, down: 0};
                    ip_stats[ip].up += (ip_stat.upload || 0);
                    ip_stats[ip].down += (ip_stat.download || 0);
                }
            }
        }

        // 2.1 获取上一次的累计总量（从状态表）
        let last_up_total = 0;
        let last_down_total = 0;
        let last_query = sprintf("sqlite3 %s \"SELECT upload, download FROM traffic_last_capture WHERE key = 'last';\"",
            shell_quote(DB_PATH));
        let last_p = popen(last_query);
        if (last_p) {
            let last_line = last_p.read('line');
            if (last_line) {
                let parts = split(last_line, "|");
                if (length(parts) >= 2) {
                    last_up_total = int(parts[0]) || 0;
                    last_down_total = int(parts[1]) || 0;
                }
            }
            last_p.close();
        }

        // 2.2 计算增量（当前值 - 上次值）
        // 如果差值为负，说明计数器重置，直接使用当前值
        let up_delta = up_total - last_up_total;
        let down_delta = down_total - last_down_total;
        if (up_delta < 0) up_delta = up_total;
        if (down_delta < 0) down_delta = down_total;

        // 2.3 更新状态表（存储本次的累计总量，供下次采集使用）
        let update_last_query = sprintf(
            "INSERT INTO traffic_last_capture VALUES ('last', %d, %d) ON CONFLICT(key) DO UPDATE SET upload=%d, download=%d;",
            up_total, down_total, up_total, down_total);
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(update_last_query)))?.close();

        // 2.3 获取上一次的 IP 累计值（用于计算 IP 增量）
        let last_ip_stats = {};
        let ip_query = sprintf("sqlite3 %s \"SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s';\"",
            shell_quote(DB_PATH), today_str);
        let ip_p = popen(ip_query);
        if (ip_p) {
            let line;
            while ((line = ip_p.read('line')) != null) {
                let parts = split(line, "|");
                if (length(parts) >= 3) {
                    let ip = parts[0];
                    let up = int(parts[1]) || 0;
                    let down = int(parts[2]) || 0;
                    last_ip_stats[ip] = {up: up, down: down};
                }
            }
            ip_p.close();
        }

        // 4. 写入数据库（使用事务合并所有写入，减少进程启动开销）
        let now = time();

        // 使用 localtime 内置函数替代 popen("date")，减少子进程开销
        let t = localtime(now);
        let today_str = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
        let month_str = sprintf('%d-%02d', t.year, t.mon);
        let time_str = sprintf('%02d:%02d', t.hour, t.min);
        let year_str = sprintf('%d', t.year);

        // 构建批量 SQL 事务
        let sql_batch = "BEGIN TRANSACTION;\n";

        // 全局总量（日）- 存储当天累计值（使用增量累加）
        sql_batch += sprintf(
            "INSERT INTO traffic_daily VALUES ('%s', %d, %d, %d) ON CONFLICT(date) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;\n",
            today_str, up_delta, down_delta, now, up_delta, down_delta, now
        );

        // 全局总量（月）- 存储当月累计值（使用增量累加）
        sql_batch += sprintf(
            "INSERT INTO traffic_monthly VALUES ('%s', %d, %d, %d) ON CONFLICT(month) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;\n",
            month_str, up_delta, down_delta, now, up_delta, down_delta, now
        );

        // 年度总量 - 存储当年累计值（使用增量累加）
        sql_batch += sprintf(
            "INSERT INTO traffic_yearly VALUES ('%s', %d, %d, %d) ON CONFLICT(year) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;\n",
            year_str, up_delta, down_delta, now, up_delta, down_delta, now
        );

        // 分钟级数据 - 存储本分钟增量（这一分钟的流量，累加）
        sql_batch += sprintf(
            "INSERT INTO traffic_minute VALUES ('%s', '%s', %d, %d) ON CONFLICT(date, time) DO UPDATE SET upload=upload+%d, download=download+%d;\n",
            today_str, time_str, up_delta, down_delta, up_delta, down_delta
        );

        // IP 统计（批量写入，使用增量累加）
        for (let ip, s in ip_stats) {
            // 计算 IP 增量（当前累计值 - 上次累计值）
            let last_ip = last_ip_stats[ip] || {up: 0, down: 0};
            let ip_up_delta = s.up - last_ip.up;
            let ip_down_delta = s.down - last_ip.down;
            
            // 如果差值为负，说明计数器重置，直接使用当前值
            if (ip_up_delta < 0) ip_up_delta = s.up;
            if (ip_down_delta < 0) ip_down_delta = s.down;
            
            sql_batch += sprintf(
                "INSERT INTO traffic_ip_daily VALUES ('%s', '%s', %d, %d) ON CONFLICT(date, ip) DO UPDATE SET upload=upload+%d, download=download+%d;\n",
                today_str, ip, ip_up_delta, ip_down_delta, ip_up_delta, ip_down_delta
            );
        }

        sql_batch += "COMMIT;\n";

        // 单次 sqlite3 进程执行所有写入
        let sql_cmd = sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_batch));
        let p_write = popen(sql_cmd);
        if (p_write) p_write.close();

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

        // 合并清理 SQL 为单个事务（只启动 1 个 sqlite3 进程）
        let cleanup_sql = sprintf(
            "BEGIN TRANSACTION;" +
            "DELETE FROM traffic_daily WHERE date < date('now', '-%d days');" +
            "DELETE FROM traffic_monthly WHERE month < strftime('%%Y-%%m', date('now', '-%d months'));" +
            "DELETE FROM traffic_ip_daily WHERE date < date('now', '-%d days');" +
            "DELETE FROM traffic_minute WHERE date < date('now', '-1 day');" +
            "COMMIT;",
            retain_days, retain_days, retain_days
        );
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(cleanup_sql)))?.close();

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
        // 使用 localtime 内置函数替代 popen("date")
        let t = localtime(time());
        let today = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
        let month = sprintf('%d-%02d', t.year, t.mon);
        let year = sprintf('%d', t.year);

        if (period == 'year') {
            date_val = year;
        } else if (period == 'month') {
            date_val = month;
        } else {
            date_val = today;
        }
    }

    // 获取当前时间用于过滤
    let now_time = '';
    if (period == 'day') {
        let t = localtime(time());
        now_time = sprintf('%02d:%02d', t.hour, t.min);
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
    let t = localtime(time());
    let today = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
    let p3 = popen(db_cmd + shell_quote(sprintf(
        "SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 10;", today
    )));
    if (p3) { res.top_ip = json(p3.read('all')) || []; p3.close(); }
    
    print(json(res));
}

// ========== 清理旧数据 ==========

function cleanup(retain_days) {
    if (!retain_days) retain_days = 30;

    // 合并所有清理 SQL 为单个事务（只启动 1 个 sqlite3 进程）
    let cleanup_sql = sprintf(
        "BEGIN TRANSACTION;" +
        "DELETE FROM traffic_daily WHERE date < date('now', '-%d days');" +
        "DELETE FROM traffic_monthly WHERE month < strftime('%%Y-%%m', date('now', '-%d months'));" +
        "DELETE FROM traffic_yearly WHERE year < strftime('%%Y', date('now', '-%d years'));" +
        "DELETE FROM traffic_ip_daily WHERE date < date('now', '-%d days');" +
        "DELETE FROM traffic_minute WHERE date < date('now', '-1 day');" +
        "DELETE FROM traffic_minute WHERE date != date('now');" +
        "COMMIT;",
        retain_days, retain_days, retain_days, retain_days
    );
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(cleanup_sql)))?.close();

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
