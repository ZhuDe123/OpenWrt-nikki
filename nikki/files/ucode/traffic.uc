#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc

import { open, mkdir, stat } from 'fs';
import { cursor } from 'sqlite3';
import { connect } from 'ubus';
import { urldecode_params } from 'luci.http';

const DB_PATH = '/tmp/nikki/traffic.db';
const STATE_FILE = '/tmp/nikki/traffic_state.json';
const MAX_IP_STATS = 50;  // 最多统计前 50 个 IP

// ========== 状态管理 ==========

function load_state() {
    let f = open(STATE_FILE, 'r');
    if (f) {
        let data = f:read('all');
        f:close();
        return json(data) || {};
    }
    return { uploadTotal: 0, downloadTotal: 0, timestamp: time(), last_cleanup: 0 };
}

function save_state(state) {
    let f = open(STATE_FILE, 'w');
    f:write(json(state, true));
    f:close();
}

// ========== 数据库初始化 ==========

function init_db() {
    mkdir('/tmp/nikki');
    
    let db = cursor();
    
    // 性能优化组合
    db:execute('PRAGMA journal_mode=WAL');
    db:execute('PRAGMA synchronous=OFF');
    db:execute('PRAGMA cache_size=-4096');  // 4MB
    db:execute('PRAGMA temp_store=MEMORY');
    db:execute('PRAGMA mmap_size=268435456');  // 256MB
    
    // 每日统计表
    db:execute(`
        CREATE TABLE IF NOT EXISTS traffic_daily (
            date TEXT PRIMARY KEY,
            upload_total INTEGER DEFAULT 0,
            download_total INTEGER DEFAULT 0,
            updated_at INTEGER
        )
    `);
    
    // 每小时统计表
    db:execute(`
        CREATE TABLE IF NOT EXISTS traffic_hourly (
            datetime TEXT PRIMARY KEY,
            upload INTEGER DEFAULT 0,
            download INTEGER DEFAULT 0,
            updated_at INTEGER
        )
    `);
    
    // IP 流量统计表
    db:execute(`
        CREATE TABLE IF NOT EXISTS traffic_ip_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            hour INTEGER NOT NULL,
            ip_address TEXT NOT NULL,
            upload INTEGER DEFAULT 0,
            download INTEGER DEFAULT 0,
            UNIQUE(date, hour, ip_address)
        )
    `);
    
    db:execute(`CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_stats(date, hour)`);
    db:execute(`CREATE INDEX IF NOT EXISTS idx_hourly ON traffic_hourly(datetime)`);
    
    return db;
}

// ========== 数据采集 ==========

function get_traffic_stats() {
    // 通过 ubus 调用 nikki 接口
    let ubus = connect();
    let res = ubus:call('nikki', 'traffic');
    
    if (res && res.uploadTotal != null) {
        return res;
    }
    
    // 降级：直接 HTTP API
    let http = require('http');
    try {
        let resp = http.get('http://127.0.0.1:9090/traffic');
        return json(resp.body);
    } catch (e) {
        warn(`Failed to get traffic stats: ${e}`);
        return { uploadTotal: 0, downloadTotal: 0, connections: [] };
    }
}

function calc_delta(current, last) {
    let up_delta = current.uploadTotal - last.uploadTotal;
    let down_delta = current.downloadTotal - last.downloadTotal;
    
    // 内核重启检测（累计值重置）
    if (up_delta < 0) up_delta = current.uploadTotal;
    if (down_delta < 0) down_delta = current.downloadTotal;
    
    return { upload: up_delta, download: down_delta };
}

function collect_traffic() {
    let db = init_db();
    let stats = get_traffic_stats();
    let last = load_state();
    let now = time();
    
    // 时间回退检测
    if (now < last.timestamp) {
        warn(`Time rollback detected: now=${now}, last=${last.timestamp}. Skipping collection.`);
        return;
    }
    
    let delta = calc_delta(stats, last);
    let today = strftime('%Y-%m-%d', now);
    let this_hour = strftime('%Y-%m-%d %H:00', now);
    let current_hour = int(strftime('%H', now));
    
    // 预编译 SQL 语句（性能优化）
    let stmt_daily = db:prepare(`
        INSERT OR REPLACE INTO traffic_daily 
        (date, upload_total, download_total, updated_at)
        VALUES (?, ?, ?, ?)
    `);
    
    let stmt_hourly = db:prepare(`
        INSERT OR REPLACE INTO traffic_hourly 
        (datetime, upload, download, updated_at)
        VALUES (?, ?, ?, ?)
    `);
    
    let stmt_ip = db:prepare(`
        INSERT OR REPLACE INTO traffic_ip_stats 
        (date, hour, ip_address, upload, download)
        VALUES (?, ?, ?, ?, ?)
    `);
    
    db:execute('BEGIN TRANSACTION');
    
    try {
        // 更新每日统计
        let daily_q = db:query(`SELECT upload_total, download_total FROM traffic_daily WHERE date='${today}'`);
        let exist_up = daily_q[0]?.upload_total || 0;
        let exist_down = daily_q[0]?.download_total || 0;
        
        stmt_daily:bind(1, today);
        stmt_daily:bind(2, exist_up + delta.upload);
        stmt_daily:bind(3, exist_down + delta.download);
        stmt_daily:bind(4, now);
        stmt_daily:step();
        stmt_daily:reset();
        
        // 更新每小时统计
        let hourly_q = db:query(`SELECT upload, download FROM traffic_hourly WHERE datetime='${this_hour}'`);
        exist_up = hourly_q[0]?.upload || 0;
        exist_down = hourly_q[0]?.download || 0;
        
        stmt_hourly:bind(1, this_hour);
        stmt_hourly:bind(2, exist_up + delta.upload);
        stmt_hourly:bind(3, exist_down + delta.download);
        stmt_hourly:bind(4, now);
        stmt_hourly:step();
        stmt_hourly:reset();
        
        // IP 统计（内存聚合 + 限制数量）
        let ip_map = {};
        if (stats.connections && length(stats.connections) > 0) {
            for (let conn in stats.connections) {
                let ip = conn.metadata?.sourceIP || 'unknown';
                if (!ip_map[ip]) {
                    ip_map[ip] = { upload: 0, download: 0 };
                }
                ip_map[ip].upload += conn.upload || 0;
                ip_map[ip].download += conn.download || 0;
            }
        }
        
        // 排序并取前 N 个
        let ip_list = [];
        for (let ip in keys(ip_map)) {
            push(ip_list, {
                ip: ip,
                up: ip_map[ip].upload,
                down: ip_map[ip].download,
                total: ip_map[ip].upload + ip_map[ip].download
            });
        }
        
        ip_list = sort(ip_list, (a, b) => b.total - a.total);
        ip_list = slice(ip_list, 0, MAX_IP_STATS);
        
        // 批量写入 IP 统计
        for (let item in ip_list) {
            stmt_ip:bind(1, today);
            stmt_ip:bind(2, current_hour);
            stmt_ip:bind(3, item.ip);
            stmt_ip:bind(4, item.up);
            stmt_ip:bind(5, item.down);
            stmt_ip:step();
            stmt_ip:reset();
        }
        
        db:execute('COMMIT');
        
        // 更新状态
        last.uploadTotal = stats.uploadTotal;
        last.downloadTotal = stats.downloadTotal;
        last.timestamp = now;
        save_state(last);
        
        // 清理旧数据（每天一次）
        if (now - last.last_cleanup > 86400) {
            cleanup_old_data(db, today);
            last.last_cleanup = now;
            save_state(last);
        }
        
    } catch (e) {
        db:execute('ROLLBACK');
        warn(`Traffic collect error: ${e}`);
    }
    
    // 清理资源
    stmt_daily:finalize();
    stmt_hourly:finalize();
    stmt_ip:finalize();
}

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