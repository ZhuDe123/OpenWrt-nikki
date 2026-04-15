#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc - 完整流量统计脚本
// 支持：全局总量 + 活跃 IP + 已关闭 IP

import { open, mkdir, chmod, stat, popen } from 'fs';
import { connect } from 'ubus';

const DB_PATH = '/tmp/nikki/traffic.db';
const PERSIST_DB = '/etc/nikki/traffic.db.bak';
const STATE_FILE = '/tmp/nikki/traffic_state.json';
const API_SECRET = '163177';  // 请替换为你的 API secret

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
            CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS traffic_hourly (datetime TEXT PRIMARY KEY, upload INTEGER, download INTEGER, updated_at INTEGER);
            CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(date, ip));
            CREATE TABLE IF NOT EXISTS traffic_ip_hourly (datetime TEXT, ip TEXT, upload INTEGER, download INTEGER, PRIMARY KEY(datetime, ip));
        `;
        let p = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(schema)));
        if (p) p.close();
    }
    chmod(DB_PATH, 0600);
}

// ========== 数据采集 ==========

function collect_traffic() {
    init_db();
    
    // 1. 获取全局总量（非流式 API）
    let p1 = popen(get_api_url("/traffic/latest"));
    let traffic_res = p1 ? p1.read('all') : '{}';
    if (p1) p1.close();
    
    let traffic_data = json(traffic_res);
    if (!traffic_data || !traffic_data.upTotal) {
        log("Warning: Cannot get traffic data");
        return;
    }
    
    let up_total = traffic_data.upTotal || 0;
    let down_total = traffic_data.downTotal || 0;
    
    // 2. 获取活跃连接的 IP 统计
    let ip_stats = {};
    let p2 = popen(get_api_url("/connections") + " | head -c 10000");
    let conn_res = p2 ? p2.read('all') : '{}';
    if (p2) p2.close();
    
    let conn_data = json(conn_res);
    if (conn_data && conn_data.connections) {
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
    let p3 = popen(get_api_url("/traffic/closed") + " | head -c 10000");
    let closed_res = p3 ? p3.read('all') : '{}';
    if (p3) p3.close();
    
    let closed_data = json(closed_res);
    if (closed_data && closed_data.closedConnections) {
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
    let today = popen("date +%Y-%m-%d");
    let today_str = today ? trim(today.read('all')) : '';
    if (today) today.close();
    
    let hour = popen("date +%H");
    let hour_str = hour ? trim(hour.read('all')) : '';
    if (hour) hour.close();
    
    let hour_full = today_str + " " + hour_str + ":00";
    
    // 写入全局总量
    let sql_global = sprintf(
        "INSERT INTO traffic_daily VALUES ('%s', %d, %d, %d) ON CONFLICT(date) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;",
        today_str, up_total, down_total, now, up_total, down_total, now
    );
    let p4 = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_global)));
    if (p4) p4.close();
    
    // 写入 IP 统计
    for (let ip, s in ip_stats) {
        let sql_ip = sprintf(
            "INSERT INTO traffic_ip_daily VALUES ('%s', '%s', %d, %d) ON CONFLICT(date, ip) DO UPDATE SET upload=upload+%d, download=download+%d;",
            today_str, ip, s.up, s.down, s.up, s.down
        );
        let p5 = popen(sprintf("sqlite3 %s %s", shell_quote(DB_PATH), shell_quote(sql_ip)));
        if (p5) p5.close();
    }
    
    log(sprintf("Collected: Total(up=%d, down=%d), IPs=%d", up_total, down_total, length(ip_stats)));
}

// ========== 数据持久化 ==========

function persist() {
    if (!stat(DB_PATH)) return;
    log("Starting backup...");
    let cmd = sprintf("sqlite3 %s '.backup %s'", shell_quote(DB_PATH), shell_quote(PERSIST_DB));
    let ret = popen(cmd);
    if (ret) ret.close();
    log("Backup completed");
}

// ========== 数据查询 ==========

function query_stats(period, date_val) {
    if (!date_val || !match(date_val, /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)) {
        print('{"error": "invalid date"}');
        return;
    }
    
    let db_cmd = sprintf("sqlite3 -json %s ", shell_quote(DB_PATH));
    let res = { global: [], ip: [] };
    
    if (period == 'day') {
        let p = popen(db_cmd + shell_quote(sprintf(
            "SELECT * FROM traffic_daily WHERE date = '%s';", date_val
        )));
        if (p) { res.global = json(p.read('all')) || []; p.close(); }
        
        let p2 = popen(db_cmd + shell_quote(sprintf(
            "SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 20;", date_val
        )));
        if (p2) { res.ip = json(p2.read('all')) || []; p2.close(); }
    }
    
    print(json(res));
}

// ========== CLI 入口 ==========

let action = ARGV[0];

if (action == 'collect') {
    collect_traffic();
} else if (action == 'persist') {
    persist();
} else if (action == 'stats') {
    query_stats(ARGV[1] || 'day', ARGV[2]);
} else {
    print('Usage: traffic.uc <collect|persist|stats> [args...]\n');
    print('  collect  - 采集当前流量数据\n');
    print('  persist  - 备份数据库到 flash\n');
    print('  stats    - 查询统计数据\n');
}
