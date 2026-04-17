#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc - 完整流量统计脚本（使用 /traffic/ip API）
// 支持：全局总量 + 各 IP 流量（活跃 + 已关闭）+ 按月统计
// 增强：完整日志记录（正常+错误）+ 自动日志裁剪

import { open, mkdir, chmod, stat, popen } from 'fs';
import { cursor } from 'uci';

const DB_PATH = '/tmp/nikki/traffic.db';
const PERSIST_DB = '/etc/nikki/traffic.db.bak';
const LOG_FILE = '/tmp/nikki/traffic.log';
const MAX_LOG_SIZE = 1024 * 100; // 100 KB

const uci = cursor();
const API_SECRET = uci.get('nikki', 'mixin', 'api_secret') || '';

// ========== 增强版日志工具：支持正常日志 + 错误日志 + 自动裁剪 ==========
function log(msg) {
    let t = localtime(time());
    let timestamp = sprintf('%d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
    let log_line = sprintf("[%s] [Traffic] %s\n", timestamp, msg);

    // 自动限制日志大小
    if (stat(LOG_FILE)) {
        let st = stat(LOG_FILE);
        if (st && st.size > MAX_LOG_SIZE) {
            let lines = [];
            let f = open(LOG_FILE, 'r');
            if (f) {
                let line;
                while ((line = f.read('line')) != null) push(lines, line);
                f.close();
                if (length(lines) > 50) lines = slice(lines, length(lines) - 50);
                f = open(LOG_FILE, 'w');
                if (f) {
                    for (let i = 0; i < length(lines); i++) f.write(lines[i]);
                    f.close();
                }
            }
        }
    }

    let f = open(LOG_FILE, 'a');
    if (f) {
        f.write(log_line);
        f.close();
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
    let init_flag = '/tmp/nikki/traffic.db.init';
    if (stat(init_flag)) return;

    popen(sprintf("sqlite3 %s 'PRAGMA journal_mode=WAL;'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_monthly (month TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_yearly (year TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, ip));'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_minute (date TEXT, time TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, time));'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_last_capture (key TEXT PRIMARY KEY, upload INTEGER, download INTEGER, last_seen INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", shell_quote(DB_PATH)))?.close();
    chmod(DB_PATH, 0600);

    let flag = open(init_flag, 'w');
    if (flag) { flag.write('1'); flag.close(); }
    log("Database initialized successfully");
}

// ========== 数据采集 ==========
function collect_traffic() {
    init_db();

    // 检查并迁移旧表（每次采集时检查）
    let check_migration = sprintf("sqlite3 %s \"PRAGMA table_info(traffic_last_capture);\" | grep -c 'last_seen'", shell_quote(DB_PATH));
    let migration_p = popen(check_migration);
    if (migration_p) {
        let has_field = trim(migration_p.read('all') || '0');
        migration_p.close();
        if (has_field == '0') {
            log("Migrating traffic_last_capture table: adding last_seen column");
            popen(sprintf("sqlite3 %s \"CREATE TABLE IF NOT EXISTS traffic_last_capture_old AS SELECT key, upload, download FROM traffic_last_capture;\"", shell_quote(DB_PATH)))?.close();
            popen(sprintf("sqlite3 %s \"DROP TABLE traffic_last_capture;\"", shell_quote(DB_PATH)))?.close();
            popen(sprintf("sqlite3 %s \"CREATE TABLE traffic_last_capture (key TEXT PRIMARY KEY, upload INTEGER, download INTEGER, last_seen INTEGER);\"", shell_quote(DB_PATH)))?.close();
            popen(sprintf("sqlite3 %s \"INSERT INTO traffic_last_capture (key, upload, download, last_seen) SELECT key, upload, download, CAST(strftime('%%s','now') AS INTEGER) FROM traffic_last_capture_old;\"", shell_quote(DB_PATH)))?.close();
            popen(sprintf("sqlite3 %s \"DROP TABLE traffic_last_capture_old;\"", shell_quote(DB_PATH)))?.close();
            log("Migration completed successfully");
        }
    }

    let lock_file = '/tmp/nikki/traffic.lock';
    if (stat(lock_file)) {
        let lock_p = open(lock_file, 'r');
        if (lock_p) {
            let lock_pid = trim(lock_p.read('all') || '');
            lock_p.close();
            if (lock_pid && stat('/proc/' + lock_pid)) {
                log("Warning: Another collection is running, skipping");
                return;
            }
            system("rm -f " + lock_file);
        }
    }

    let my_pid = popen("cat /proc/self/stat 2>/dev/null | cut -d' ' -f1");
    let pid_str = my_pid ? trim(my_pid.read('all')) : '0';
    if (my_pid) my_pid.close();

    let lock = open(lock_file, 'w');
    if (lock) { lock.write(pid_str); lock.close(); }

    function release_lock() { system("rm -f " + lock_file); }

    try {
        // Step 1: 从 API 获取原始数据（ucode 只做搬运）
        let p1 = popen(get_api_url("/traffic/summary"));
        let summary_res = p1 ? p1.read('all') : '{}';
        if (p1) p1.close();

        let summary_data = summary_res && match(summary_res, /^\s*\{/) ? json(summary_res) : {};
        if (!summary_data || !summary_data.upTotal) {
            log("Error: Failed to get traffic data from /traffic/summary");
            release_lock();
            return;
        }

        let up_total = summary_data.upTotal || 0;
        let down_total = summary_data.downTotal || 0;
        
        // 调试：打印 JSON 解析结果
        log(sprintf("DEBUG: upTotal=%d downTotal=%d ipStats type=%s", up_total, down_total, type(summary_data.ipStats)));
        if (summary_data.ipStats) {
            log(sprintf("DEBUG: ipStats length=%d", length(summary_data.ipStats)));
        }
        
        let now = time();
        let t = localtime(now);
        let today_str = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
        let month_str = sprintf('%d-%02d', t.year, t.mon);
        let time_str = sprintf('%02d:%02d', t.hour, t.min);
        let year_str = sprintf('%d', t.year);

        // Step 2: 收集当前所有 IP 及其原始值（不计算差值）
        let ip_list = [];
        let ip_values = {};
        let ip_seen = {};  // 用于去重
        if (summary_data.ipStats) {
            for (let i = 0; i < length(summary_data.ipStats); i++) {
                let ip_stat = summary_data.ipStats[i];
                let ip = ip_stat.ip;
                if (ip && ip != 'unknown' && ip != 'invalid IP') {
                    if (!ip_values[ip]) ip_values[ip] = { up: 0, down: 0 };
                    ip_values[ip].up += ip_stat.upload || 0;
                    ip_values[ip].down += ip_stat.download || 0;
                    if (!ip_seen[ip]) {
                        ip_seen[ip] = true;
                        push(ip_list, ip);
                    }
                }
            }
        }
        
        // 调试：打印 IP 列表
        log(sprintf("DEBUG: Found %d unique IPs: %s", length(ip_list), join(", ", ip_list)));

        // Step 3: 构建 SQL（所有增量计算在 SQLite 内部完成）
        // 注意：必须先计算增量，最后才更新快照！否则读取到新值就错了
        let sql = "BEGIN;\n";

        // 3.1 全局流量：先计算增量并累加（此时读取的是旧快照）
        sql += sprintf("INSERT INTO traffic_daily VALUES ('%s', 0, 0, %d) ", today_str, now);
        sql += "ON CONFLICT(date) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END), ", down_total);
        sql += sprintf("updated_at = %d;\n", now);

        sql += sprintf("INSERT INTO traffic_monthly VALUES ('%s', 0, 0, %d) ", month_str, now);
        sql += "ON CONFLICT(month) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END), ", down_total);
        sql += sprintf("updated_at = %d;\n", now);

        sql += sprintf("INSERT INTO traffic_yearly VALUES ('%s', 0, 0, %d) ", year_str, now);
        sql += "ON CONFLICT(year) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END), ", down_total);
        sql += sprintf("updated_at = %d;\n", now);

        sql += sprintf("INSERT INTO traffic_minute VALUES ('%s', '%s', 0, 0) ", today_str, time_str);
        sql += "ON CONFLICT(date, time) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END);\n", down_total);

        // 3.2 IP 流量：先计算增量并累加（此时读取的是旧快照）
        for (let i = 0; i < length(ip_list); i++) {
            let ip = ip_list[i];
            let s = ip_values[ip];

            // 第一次 INSERT 时初始化当前值（不是 0），后续才累加增量
            sql += sprintf("INSERT INTO traffic_ip_daily VALUES ('%s', '%s', COALESCE((SELECT upload FROM traffic_last_capture WHERE key='ip:%s'), %d), COALESCE((SELECT download FROM traffic_last_capture WHERE key='ip:%s'), %d)) ", today_str, ip, ip, s.up, ip, s.down);
            sql += "ON CONFLICT(date, ip) DO UPDATE SET ";
            sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.up, ip);
            sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.up, ip);
            sql += sprintf("ELSE %d END), ", s.up);
            sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.down, ip);
            sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.down, ip);
            sql += sprintf("ELSE %d END);\n", s.down);
        }

        // 3.3 最后才更新快照（这样前面的计算读到的是旧值）
        sql += sprintf("INSERT INTO traffic_last_capture VALUES ('last', %d, %d, %d) ", up_total, down_total, now);
        sql += "ON CONFLICT(key) DO UPDATE SET upload=excluded.upload, download=excluded.download, last_seen=excluded.last_seen;\n";

        for (let i = 0; i < length(ip_list); i++) {
            let ip = ip_list[i];
            let s = ip_values[ip];
            sql += sprintf("INSERT INTO traffic_last_capture VALUES ('ip:%s', %d, %d, %d) ", ip, s.up, s.down, now);
            sql += "ON CONFLICT(key) DO UPDATE SET upload=excluded.upload, download=excluded.download, last_seen=excluded.last_seen;\n";
        }

        // 3.4 清理过期 IP 快照（10 分钟未出现）
        sql += sprintf("DELETE FROM traffic_last_capture WHERE key LIKE 'ip:%%' AND (last_seen < %d OR last_seen IS NULL);\n", now - 600);

        sql += "COMMIT;\n";
        
        // 使用 printf + 管道执行 SQL，避免临时文件和 shell_quote 问题
        let cmd = sprintf("printf '%%s' %s | sqlite3 %s", shell_quote(sql), shell_quote(DB_PATH));
        popen(cmd)?.close();

        log(sprintf("Collect OK | up=%d down=%d ips=%d", up_total, down_total, length(ip_list)));

    } catch (e) {
        log("Error: " + e);
    }

    let now_ts = time();
    let last_clean = int(uci.get('nikki', 'traffic', 'last_cleanup') || 0);
    if (now_ts - last_clean > 86400) {
        let days = int(uci.get('nikki', 'traffic', 'retain_days') || 30);
        let clean = sprintf("BEGIN; DELETE FROM traffic_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_ip_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_minute WHERE date < date('now','-1 day'); COMMIT;", days, days);
        popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(clean)))?.close();
        uci.set('nikki', 'traffic', 'last_cleanup', now_ts);
        uci.commit('nikki');
        log("Auto-cleanup old data completed");
    }

    release_lock();
}

// ========== 持久化备份 ==========
function persist() {
    if (!stat(DB_PATH)) { log("Error: No database to backup"); return; }
    mkdir('/etc/nikki', 0755);
    popen(sprintf("sqlite3 %s '.backup %s'", shell_quote(DB_PATH), shell_quote(PERSIST_DB)))?.close();
    chmod(PERSIST_DB, 0600);
    log("Backup to flash successful");
}

// ========== 查询功能 ==========
function query_stats(period, date_val) {
    let t = localtime(time());
    if (!date_val) {
        date_val = period == 'year' ? sprintf('%d', t.year) :
               period == 'month' ? sprintf('%d-%02d', t.year, t.mon) :
               sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
    }

    let now_time = sprintf('%02d:%02d', t.hour, t.min);
    let db = DB_PATH;

    if (period == 'year') {
        let mon = '[]';
        let yea = '[]';
        if (stat(DB_PATH)) {
            let m = popen(sprintf("sqlite3 -json %s 'SELECT month, upload, download FROM traffic_monthly WHERE month LIKE \"%s-%%\" ORDER BY month;'", shell_quote(db), date_val));
            if (m) {
                let result = m.read('all');
                m.close();
                if (result && match(result, /^\s*\[/)) mon = trim(result);
            }
            let y = popen(sprintf("sqlite3 -json %s 'SELECT * FROM traffic_yearly WHERE year=\"%s\";'", shell_quote(db), date_val));
            if (y) {
                let result = y.read('all');
                y.close();
                if (result && match(result, /^\s*\[/)) yea = trim(result);
            }
        }
        return sprintf('{"monthly":%s,"yearly":%s,"ip":[]}', mon, yea);
    }

    if (period == 'month') {
        let day = '[]';
        let mon = '[]';
        if (stat(DB_PATH)) {
            let d = popen(sprintf("sqlite3 -json %s 'SELECT date, upload, download FROM traffic_daily WHERE date LIKE \"%s-%%\" ORDER BY date;'", shell_quote(db), date_val));
            if (d) {
                let result = d.read('all');
                d.close();
                if (result && match(result, /^\s*\[/)) day = trim(result);
            }
            let m = popen(sprintf("sqlite3 -json %s 'SELECT * FROM traffic_monthly WHERE month=\"%s\";'", shell_quote(db), date_val));
            if (m) {
                let result = m.read('all');
                m.close();
                if (result && match(result, /^\s*\[/)) mon = trim(result);
            }
        }
        return sprintf('{"daily":%s,"monthly":%s,"ip":[]}', day, mon);
    }

    if (period == 'day') {
        let min = '[]';
        let glo = '[]';
        let ip = '[]';
        if (stat(DB_PATH)) {
            let mi = popen(sprintf("sqlite3 -json %s 'SELECT time, upload, download FROM traffic_minute WHERE date=\"%s\" AND time<=\"%s\" ORDER BY time;'", shell_quote(db), date_val, now_time));
            if (mi) {
                let result = mi.read('all');
                mi.close();
                if (result && match(result, /^\s*\[/)) min = trim(result);
            }
            let g = popen(sprintf("sqlite3 -json %s 'SELECT * FROM traffic_daily WHERE date=\"%s\";'", shell_quote(db), date_val));
            if (g) {
                let result = g.read('all');
                g.close();
                if (result && match(result, /^\s*\[/)) glo = trim(result);
            }
            let i = popen(sprintf("sqlite3 -json %s 'SELECT ip, upload, download FROM traffic_ip_daily WHERE date=\"%s\" ORDER BY (upload+download) DESC LIMIT 50;'", shell_quote(db), date_val));
            if (i) {
                let result = i.read('all');
                i.close();
                if (result && match(result, /^\s*\[/)) ip = trim(result);
            }
        }
        return sprintf('{"minute":%s,"global":%s,"ip":%s}', min, glo, ip);
    }

    return '{"minute":[],"global":[],"ip":[]}';
}

function query_history(days) {
    days = days || 7;
    let t = localtime(time());
    let today = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
    let db = shell_quote(DB_PATH);

    let d = '[]';
    let m = '[]';
    let i = '[]';

    if (stat(DB_PATH)) {
        let daily = popen(sprintf("sqlite3 -json %s 'SELECT date, upload, download FROM traffic_daily WHERE date >= date(\"now\", \"-%d days\") ORDER BY date DESC;'", db, days));
        if (daily) {
            let result = daily.read('all');
            daily.close();
            if (result && match(result, /^\s*\[/)) d = trim(result);
        }
        let monthly = popen(sprintf("sqlite3 -json %s 'SELECT month, upload, download FROM traffic_monthly ORDER BY month DESC LIMIT 12;'", db));
        if (monthly) {
            let result = monthly.read('all');
            monthly.close();
            if (result && match(result, /^\s*\[/)) m = trim(result);
        }
        let top = popen(sprintf("sqlite3 -json %s 'SELECT ip, upload, download FROM traffic_ip_daily WHERE date=\"%s\" ORDER BY (upload+download) DESC LIMIT 10;'", db, today));
        if (top) {
            let result = top.read('all');
            top.close();
            if (result && match(result, /^\s*\[/)) i = trim(result);
        }
    }

    print(sprintf('{"daily":%s,"monthly":%s,"top_ip":%s}', d, m, i));
}

function cleanup(retain_days) {
    retain_days = retain_days || 30;
    let sql = sprintf("BEGIN; DELETE FROM traffic_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_ip_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_minute WHERE date < date('now','-1 day'); COMMIT;", retain_days, retain_days);
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql)))?.close();
    log("Manual cleanup completed: " + retain_days + " days");
}

// ========== CLI 入口 ==========
let action = ARGV[0];
if (action == 'collect') collect_traffic();
else if (action == 'persist') persist();
else if (action == 'stats') print(query_stats(ARGV[1], ARGV[2]));
else if (action == 'history') query_history(int(ARGV[1]) || 7);
else if (action == 'cleanup') cleanup(int(ARGV[1]) || 30);
else {
    print('Usage: traffic.uc collect|persist|stats|history|cleanup\n');
}