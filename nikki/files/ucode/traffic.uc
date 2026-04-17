#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc - 流量统计脚本（基于 Mihomo API）
// 功能：采集全局流量 + IP 流量 + 分钟/日/月/年度统计
// 架构：ucode 只做数据搬运，所有增量计算由 SQLite 完成（避免 32 位整数溢出）
// 设计：数据库在 /tmp 内存盘，重启自动重建，无需迁移逻辑

import { open, mkdir, chmod, stat, popen } from 'fs';
import { cursor } from 'uci';

const DB_PATH = '/tmp/nikki/traffic.db';         // 内存盘数据库（重启后重建）
const PERSIST_DB = '/etc/nikki/traffic.db.bak';  // 闪存备份（用于持久化）
const LOG_FILE = '/tmp/nikki/traffic.log';       // 日志文件路径
const MAX_LOG_SIZE = 1024 * 100;                 // 日志最大 100KB，超限自动裁剪

const uci = cursor();
const API_SECRET = uci.get('nikki', 'mixin', 'api_secret') || '';  // Mihomo API 认证密钥

// 日志函数：带时间戳 + 自动裁剪（超过 100KB 保留最后 50 行）
function log(msg) {
    let t = localtime(time());
    let timestamp = sprintf('%d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
    let log_line = sprintf("[%s] [Traffic] %s\n", timestamp, msg);

    // 自动裁剪：日志超过 100KB 时只保留最后 50 行
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

// Shell 参数转义：防止 SQL 注入和 shell 特殊字符
function shell_quote(str) {
    return str ? "'" + replace(str, "'", "'\\''") + "'" : "''";
}

// 构造 Mihomo API 请求命令（带 Bearer Token 认证）
function get_api_url(path) {
    return sprintf("curl -s -H 'Authorization: Bearer %s' 'http://127.0.0.1:9090%s'", API_SECRET, path);
}

// 数据库初始化：首次运行时创建所有表和索引
function init_db() {
    // 确保 /tmp/nikki 目录存在
    if (!stat('/tmp/nikki')) mkdir('/tmp/nikki', 0700);
    
    // 初始化标记：如果已存在说明表结构已创建，直接返回
    let init_flag = '/tmp/nikki/traffic.db.init';
    if (stat(init_flag)) return;

    // 开启 WAL 模式（提高并发写入性能）
    popen(sprintf("sqlite3 %s 'PRAGMA journal_mode=WAL;'", shell_quote(DB_PATH)))?.close();
    
    // 创建核心数据表
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_monthly (month TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_yearly (year TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, ip));'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_minute (date TEXT, time TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, time));'", shell_quote(DB_PATH)))?.close();
    // last_seen 字段：记录最后一次出现的时间，用于 10 分钟过期清理
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_last_capture (key TEXT PRIMARY KEY, upload INTEGER, download INTEGER, last_seen INTEGER);'", shell_quote(DB_PATH)))?.close();
    
    // 创建索引（加速查询）
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", shell_quote(DB_PATH)))?.close();
    
    // 设置数据库权限（仅 root 可读写）
    chmod(DB_PATH, 0600);

    // 创建初始化标记文件
    let flag = open(init_flag, 'w');
    if (flag) { flag.write('1'); flag.close(); }
    log("Database initialized successfully");
}

// 流量采集主函数：从 Mihomo API 获取数据并写入数据库
function collect_traffic() {
    init_db();
    // 注意：数据库在 /tmp 内存盘，重启后自动重建，无需表迁移逻辑
    // 全新安装或重装时，init_db() 会直接创建包含 last_seen 字段的完整表结构

    // ===== 分布式锁：防止并发采集导致数据错乱 =====
    let lock_file = '/tmp/nikki/traffic.lock';
    if (stat(lock_file)) {
        let lock_p = open(lock_file, 'r');
        if (lock_p) {
            let lock_pid = trim(lock_p.read('all') || '');
            lock_p.close();
            // 检查锁对应的进程是否还在运行
            if (lock_pid && stat('/proc/' + lock_pid)) {
                log("Warning: Another collection is running, skipping");
                return;
            }
            // 进程已退出，清理过期锁文件
            system("rm -f " + lock_file);
        }
    }

    // 获取当前进程 PID 并写入锁文件
    let my_pid = popen("cat /proc/self/stat 2>/dev/null | cut -d' ' -f1");
    let pid_str = my_pid ? trim(my_pid.read('all')) : '0';
    if (my_pid) my_pid.close();

    let lock = open(lock_file, 'w');
    if (lock) { lock.write(pid_str); lock.close(); }

    // 释放锁函数
    function release_lock() { system("rm -f " + lock_file); }

    try {
        // Step 1: 从 Mihomo API 获取原始流量数据（ucode 只做搬运，不计算）
        let p1 = popen(get_api_url("/traffic/summary"));
        let summary_res = p1 ? p1.read('all') : '{}';
        if (p1) p1.close();

        // 验证 JSON 格式和必要字段
        let summary_data = summary_res && match(summary_res, /^\s*\{/) ? json(summary_res) : {};
        if (!summary_data || !summary_data.upTotal) {
            log("Error: Failed to get traffic data from /traffic/summary");
            release_lock();
            return;
        }

        // 提取全局累计值（从 Mihomo 服务启动到现在的总量）
        let up_total = summary_data.upTotal || 0;
        let down_total = summary_data.downTotal || 0;
        
        // 计算当前时间信息（用于数据库记录）
        let now = time();
        let t = localtime(now);
        let today_str = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
        let month_str = sprintf('%d-%02d', t.year, t.mon);
        let time_str = sprintf('%02d:%02d', t.hour, t.min);
        let year_str = sprintf('%d', t.year);

        // Step 2: 收集当前所有活跃 IP 及其原始累计值（不计算差值）
        let ip_list = [];
        let ip_values = {};
        let ip_seen = {};  // 哈希表用于去重
        if (summary_data.ipStats) {
            for (let i = 0; i < length(summary_data.ipStats); i++) {
                let ip_stat = summary_data.ipStats[i];
                let ip = ip_stat.ip;
                // 过滤无效 IP
                if (ip && ip != 'unknown' && ip != 'invalid IP') {
                    if (!ip_values[ip]) ip_values[ip] = { up: 0, down: 0 };
                    ip_values[ip].up += ip_stat.upload || 0;
                    ip_values[ip].down += ip_stat.download || 0;
                    // 去重：同一个 IP 只加入列表一次
                    if (!ip_seen[ip]) {
                        ip_seen[ip] = true;
                        push(ip_list, ip);
                    }
                }
            }
        }
        
        // 调试：打印 IP 列表
        log(sprintf("DEBUG: Found %d unique IPs: %s", length(ip_list), join(", ", ip_list)));

        // Step 3: 构建 SQL（所有增量计算在 SQLite 内部完成，避免 ucode 32 位整数溢出）
        // 核心公式：增量 = (当前值 >= 旧值) ? (当前值 - 旧值) : 当前值（处理服务重启）
        // 执行顺序：先计算增量（读取旧快照）→ 最后才更新快照
        let sql = "BEGIN;\n";

        // 3.1 全局流量：累加今日/本月/本年的增量（此时读取的是 traffic_last_capture 中的旧快照）
        // 日级统计
        sql += sprintf("INSERT INTO traffic_daily VALUES ('%s', 0, 0, %d) ", today_str, now);
        sql += "ON CONFLICT(date) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END), ", down_total);
        sql += sprintf("updated_at = %d;\n", now);

        // 月级统计
        sql += sprintf("INSERT INTO traffic_monthly VALUES ('%s', 0, 0, %d) ", month_str, now);
        sql += "ON CONFLICT(month) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END), ", down_total);
        sql += sprintf("updated_at = %d;\n", now);

        // 年级统计
        sql += sprintf("INSERT INTO traffic_yearly VALUES ('%s', 0, 0, %d) ", year_str, now);
        sql += "ON CONFLICT(year) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END), ", down_total);
        sql += sprintf("updated_at = %d;\n", now);

        // 分钟级统计
        sql += sprintf("INSERT INTO traffic_minute VALUES ('%s', '%s', 0, 0) ", today_str, time_str);
        sql += "ON CONFLICT(date, time) DO UPDATE SET ";
        sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='last'), 0) ", up_total);
        sql += sprintf("ELSE %d END), ", up_total);
        sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='last'), 0) ", down_total);
        sql += sprintf("ELSE %d END);\n", down_total);

        // 3.2 IP 流量：为每个活跃 IP 累加增量（逻辑同全局流量）
        for (let i = 0; i < length(ip_list); i++) {
            let ip = ip_list[i];
            let s = ip_values[ip];

            // 首次插入：用旧快照值初始化（避免从 0 开始导致第一次增量为当前值）
            // 后续更新：累加增量
            sql += sprintf("INSERT INTO traffic_ip_daily VALUES ('%s', '%s', COALESCE((SELECT upload FROM traffic_last_capture WHERE key='ip:%s'), %d), COALESCE((SELECT download FROM traffic_last_capture WHERE key='ip:%s'), %d)) ", today_str, ip, ip, s.up, ip, s.down);
            sql += "ON CONFLICT(date, ip) DO UPDATE SET ";
            sql += sprintf("upload = upload + (CASE WHEN %d >= COALESCE((SELECT upload FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.up, ip);
            sql += sprintf("THEN %d - COALESCE((SELECT upload FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.up, ip);
            sql += sprintf("ELSE %d END), ", s.up);
            sql += sprintf("download = download + (CASE WHEN %d >= COALESCE((SELECT download FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.down, ip);
            sql += sprintf("THEN %d - COALESCE((SELECT download FROM traffic_last_capture WHERE key='ip:%s'), 0) ", s.down, ip);
            sql += sprintf("ELSE %d END);\n", s.down);
        }

        // 3.3 更新快照：所有增量计算完成后，才更新 traffic_last_capture（存储当前 API 值）
        // 更新全局快照
        sql += sprintf("INSERT INTO traffic_last_capture VALUES ('last', %d, %d, %d) ", up_total, down_total, now);
        sql += "ON CONFLICT(key) DO UPDATE SET upload=excluded.upload, download=excluded.download, last_seen=excluded.last_seen;\n";

        // 更新各 IP 快照
        for (let i = 0; i < length(ip_list); i++) {
            let ip = ip_list[i];
            let s = ip_values[ip];
            sql += sprintf("INSERT INTO traffic_last_capture VALUES ('ip:%s', %d, %d, %d) ", ip, s.up, s.down, now);
            sql += "ON CONFLICT(key) DO UPDATE SET upload=excluded.upload, download=excluded.download, last_seen=excluded.last_seen;\n";
        }

        // 3.4 清理过期 IP 快照：删除 10 分钟未出现的 IP（节省内存）
        sql += sprintf("DELETE FROM traffic_last_capture WHERE key LIKE 'ip:%%' AND (last_seen < %d OR last_seen IS NULL);\n", now - 600);

        sql += "COMMIT;\n";
        
        // 执行 SQL：使用 printf 管道传输，避免 shell_quote 破坏单引号
        let cmd = sprintf("printf '%%s' %s | sqlite3 %s", shell_quote(sql), shell_quote(DB_PATH));
        popen(cmd)?.close();

        log(sprintf("Collect OK | up=%d down=%d ips=%d", up_total, down_total, length(ip_list)));

    } catch (e) {
        log("Error: " + e);
    }

    // 每日自动清理：删除 30 天前的旧数据（保留策略由 UCI 配置）
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

// 持久化备份：将内存盘数据库备份到闪存（防止路由器重启丢失数据）
function persist() {
    if (!stat(DB_PATH)) { log("Error: No database to backup"); return; }
    mkdir('/etc/nikki', 0755);
    // 使用 SQLite 热备份（不影响正在进行的读写操作）
    popen(sprintf("sqlite3 %s '.backup %s'", shell_quote(DB_PATH), shell_quote(PERSIST_DB)))?.close();
    chmod(PERSIST_DB, 0600);
    log("Backup to flash successful");
}

// 从闪存恢复备份到内存盘（路由器重启后调用）
function restore() {
    if (!stat(PERSIST_DB)) {
        log("No backup found, starting fresh");
        return;
    }
    
    log("Restoring database from backup...");
    // 删除旧的内存盘数据库（如果存在）
    if (stat(DB_PATH)) system("rm -f " + shell_quote(DB_PATH));
    
    // 使用 SQLite 恢复（完整还原备份文件）
    popen(sprintf("sqlite3 %s '.restore %s'", shell_quote(DB_PATH), shell_quote(PERSIST_DB)))?.close();
    
    // 重新创建索引（恢复后索引可能丢失）
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", shell_quote(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", shell_quote(DB_PATH)))?.close();
    
    chmod(DB_PATH, 0600);
    log("Database restored successfully");
}

// 查询函数：根据时间范围查询流量统计（供前端 API 调用）
function query_stats(period, date_val) {
    let t = localtime(time());
    if (!date_val) {
        date_val = period == 'year' ? sprintf('%d', t.year) :
               period == 'month' ? sprintf('%d-%02d', t.year, t.mon) :
               sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
    }

    let now_time = sprintf('%02d:%02d', t.hour, t.min);
    let db = DB_PATH;

    // 年度视图：查询 12 个月的数据
    if (period == 'year') {
        let mon = '[]';
        let yea = '[]';
        if (stat(DB_PATH)) {
            let m = popen(sprintf("sqlite3 -json %s 'SELECT month, upload, download FROM traffic_monthly WHERE month LIKE \"%s-%%\" ORDER BY month;'", shell_quote(db), date_val));
            if (m) {
                let result = m.read('all');
                m.close();
                // 验证返回结果是合法 JSON 数组（避免空字符串导致前端解析失败）
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

    // 月份视图：查询每天的数据
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

    // 日视图：查询分钟级数据 + 今日 IP 排行
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

// 历史数据查询：返回近 N 天的日级/月级数据 + Top 10 IP
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

// 手动清理：删除指定天数前的旧数据（默认 30 天）
function cleanup(retain_days) {
    retain_days = retain_days || 30;
    let sql = sprintf("BEGIN; DELETE FROM traffic_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_ip_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_minute WHERE date < date('now','-1 day'); COMMIT;", retain_days, retain_days);
    popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql)))?.close();
    log("Manual cleanup completed: " + retain_days + " days");
}

// 清除备份数据库：删除闪存中的备份文件（释放空间）
function clear_backup() {
    if (stat(PERSIST_DB)) {
        system("rm -f " + shell_quote(PERSIST_DB));
        log("Backup cleared successfully");
    } else {
        log("No backup found");
    }
}

// ===== CLI 入口：根据命令行参数执行对应操作 =====
let action = ARGV[0];
if (action == 'collect') collect_traffic();           // 采集流量数据
else if (action == 'persist') persist();               // 持久化备份到闪存
else if (action == 'restore') restore();               // 从闪存恢复备份
else if (action == 'clear_backup') clear_backup();     // 清除备份文件
else if (action == 'stats') print(query_stats(ARGV[1], ARGV[2]));  // 查询统计
else if (action == 'history') query_history(int(ARGV[1]) || 7);    // 查询历史
else if (action == 'cleanup') cleanup(int(ARGV[1]) || 30);         // 清理旧数据
else {
    print('Usage: traffic.uc collect|persist|restore|clear_backup|stats|history|cleanup\n');
}