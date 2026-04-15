#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc - Production Stable Version
// Fixed: SQL injection, command injection, data persistence

import { open, mkdir, chmod, stat, system, popen } from 'fs';
import { connect } from 'ubus';

const DB_PATH = '/tmp/nikki/traffic.db';
const PERSIST_DB = '/etc/nikki/traffic.db.bak';
const STATE_FILE = '/tmp/nikki/traffic_state.json';
const MAX_CONN_PROCESS = 1000;

// ========== 日志与安全工具函数 ==========

function log(msg) {
    let t = strftime('%Y-%m-%d %H:%M:%S', time());
    print(sprintf("[%s] [Traffic] %s\n", t, msg));
}

function sql_escape(str) {
    return str ? "'" + replace(str, "'", "''") + "'" : "''";
}

function shell_quote(str) {
    return str ? "'" + replace(str, "'", "'\\''") + "'" : "''";
}

function run_sql_batch(sql_commands) {
    let full_sql = "PRAGMA journal_mode=WAL; BEGIN; " + sql_commands + " COMMIT;";
    let cmd = sprintf("sqlite3 %s %s 2>&1", shell_quote(DB_PATH), shell_quote(full_sql));
    let p = popen(cmd);
    let err = p ? p.read('all') : 'Pipe failed';
    let ret = p ? p.close() : -1;

    if (ret != 0) {
        log("SQL Error (Code " + ret + "): " + trim(err));
        return false;
    }
    return true;
}

// ========== 数据库初始化 ==========

function init_db() {
    if (!stat('/tmp/nikki')) mkdir('/tmp/nikki', 0700);
    
    if (!stat(DB_PATH)) {
        let schema = `
            CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS traffic_hourly (datetime TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS traffic_ip_stats (date TEXT, hour INTEGER, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, hour, ip));
        `;
        if (!run_sql_batch(schema)) {
            log("Error: Failed to create database schema");
            return;
        }
    }
    
    // 始终确保权限正确
    chmod(DB_PATH, 0600);
}

// ========== 数据采集 ==========

function collect_traffic() {
    let u = connect();
    let stats = u.call('nikki', 'traffic');
    
    if (!stats || !stats.uploadTotal) {
        log("Warning: Cannot fetch data from nikki ubus");
        return;
    }

    init_db();

    let f = open(STATE_FILE, 'r');
    let last = f ? json(f.read('all')) : { u: 0, d: 0, last_persist: 0 };
    if (f) f.close();

    let now = time();
    let up_delta = (stats.uploadTotal >= (last.u || 0)) ? (stats.uploadTotal - (last.u || 0)) : stats.uploadTotal;
    let down_delta = (stats.downloadTotal >= (last.d || 0)) ? (stats.downloadTotal - (last.d || 0)) : stats.downloadTotal;

    let today = strftime('%Y-%m-%d', now);
    let hour_full = strftime('%Y-%m-%d %H:00', now);
    let hour_num = int(strftime('%H', now));

    // 构建大事务 SQL (修复 P0: 使用 down_delta 而非 download_delta)
    let sql = sprintf(
        "INSERT INTO traffic_daily VALUES (%s,%d,%d,%d) ON CONFLICT(date) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d; ",
        sql_escape(today), up_delta, down_delta, now, up_delta, down_delta, now
    );
    sql += sprintf(
        "INSERT INTO traffic_hourly VALUES (%s,%d,%d,%d) ON CONFLICT(datetime) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d; ",
        sql_escape(hour_full), up_delta, down_delta, now, up_delta, down_delta, now
    );

    // IP 统计 (带限流)
    if (stats.connections) {
        let ip_map = {}, count = 0;
        for (let conn of stats.connections) {
            if (++count > MAX_CONN_PROCESS) {
                log("Warning: Too many connections, truncating at " + MAX_CONN_PROCESS);
                break;
            }
            let ip = conn.metadata?.sourceIP || 'unknown';
            ip_map[ip] = ip_map[ip] || { u: 0, d: 0 };
            ip_map[ip].u += (conn.upload || 0);
            ip_map[ip].d += (conn.download || 0);
        }
        
        for (let ip, s in ip_map) {
            sql += sprintf(
                "INSERT INTO traffic_ip_stats VALUES (%s,%d,%s,%d,%d) ON CONFLICT(date,hour,ip) DO UPDATE SET upload=upload+%d, download=download+%d; ",
                sql_escape(today), hour_num, sql_escape(ip), s.u, s.d, s.u, s.d
            );
        }
    }

    if (run_sql_batch(sql)) {
        // 更新状态
        last.u = stats.uploadTotal;
        last.d = stats.downloadTotal;
        
        // 每小时自动持久化
        if (!last.last_persist || (now - last.last_persist > 3600)) {
            persist();
            last.last_persist = now;
        }

        let sf = open(STATE_FILE, 'w');
        if (sf) {
            sf.write(json(last));
            sf.close();
            chmod(STATE_FILE, 0600);
        }
    }
}

// ========== 数据持久化 (修复 P0: 使用 .backup 替代 cp) ==========

function persist() {
    if (!stat(DB_PATH)) {
        log("No database file to backup");
        return;
    }
    
    log("Starting secure backup...");
    
    // 使用 sqlite3 .backup 命令进行安全热备份 (处理 WAL 模式)
    let cmd = sprintf("sqlite3 %s '.backup %s' 2>&1",
        shell_quote(DB_PATH),
        shell_quote(PERSIST_DB)
    );
    
    let ret = system(cmd);
    if (ret == 0) {
        chmod(PERSIST_DB, 0600);
        log("Backup completed successfully");
    } else {
        log("Backup failed with code " + ret);
    }
}

// ========== 数据查询 (修复 P1: 补全 month/year 周期 + popen 校验) ==========

function stats_query(period, date_val) {
    // POSIX 正则校验日期格式
    if (!date_val || !match(date_val, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) {
        print('{"error": "invalid date"}');
        return;
    }
    
    let res = { hourly: [], daily: [], ip: [] };
    let db_cmd = sprintf("sqlite3 -json %s ", shell_quote(DB_PATH));
    
    if (period == 'day') {
        // 查询小时数据
        let q_h = sprintf("SELECT datetime, upload, download FROM traffic_hourly WHERE datetime LIKE %s ORDER BY datetime ASC;", sql_escape(date_val + '%'));
        let p_h = popen(db_cmd + shell_quote(q_h));
        if (p_h) {
            let raw = p_h.read('all');
            p_h.close();
            res.hourly = json(raw) || [];
        } else {
            log("Warning: Failed to execute hourly query");
        }

        // 查询 IP 统计
        let q_ip = sprintf("SELECT ip, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_stats WHERE date = %s GROUP BY ip ORDER BY (upload+download) DESC LIMIT 15;", sql_escape(date_val));
        let p_ip = popen(db_cmd + shell_quote(q_ip));
        if (p_ip) {
            let raw = p_ip.read('all');
            p_ip.close();
            res.ip = json(raw) || [];
        } else {
            log("Warning: Failed to execute IP query");
        }
        
    } else if (period == 'month') {
        let month_val = substr(date_val, 0, 7);  // "2026-04"
        
        // 查询每日数据
        let q_d = sprintf("SELECT date, upload, download FROM traffic_daily WHERE date LIKE %s ORDER BY date ASC;", sql_escape(month_val + '%'));
        let p_d = popen(db_cmd + shell_quote(q_d));
        if (p_d) {
            let raw = p_d.read('all');
            p_d.close();
            res.daily = json(raw) || [];
        } else {
            log("Warning: Failed to execute daily query");
        }
        
        // 修复 P1: 添加该月的 IP 统计
        let q_ip = sprintf("SELECT ip, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_stats WHERE date LIKE %s GROUP BY ip ORDER BY (upload+download) DESC LIMIT 15;", sql_escape(month_val + '%'));
        let p_ip = popen(db_cmd + shell_quote(q_ip));
        if (p_ip) {
            let raw = p_ip.read('all');
            p_ip.close();
            res.ip = json(raw) || [];
        } else {
            log("Warning: Failed to execute IP query for month");
        }
        
    } else if (period == 'year') {
        let year_val = substr(date_val, 0, 4);  // "2026"
        
        // 查询每月汇总
        let q_m = sprintf("SELECT strftime('%%Y-%%m', date) as month, SUM(upload) as upload, SUM(download) as download FROM traffic_daily WHERE date LIKE %s GROUP BY month ORDER BY month ASC;", sql_escape(year_val + '%'));
        let p_m = popen(db_cmd + shell_quote(q_m));
        if (p_m) {
            let raw = p_m.read('all');
            p_m.close();
            res.daily = json(raw) || [];
        } else {
            log("Warning: Failed to execute monthly query");
        }
    }
    
    print(json(res));
}

// ========== CLI 入口 ==========

let action = ARGV[0];

if (action == 'collect') {
    collect_traffic();
} else if (action == 'stats') {
    stats_query(ARGV[1], ARGV[2]);
} else if (action == 'persist') {
    persist();
} else {
    print('Usage: traffic.uc <collect|stats|persist> [args...]');
    exit(1);
}
