#!/usr/bin/ucode
// /etc/nikki/ucode/traffic.uc

import { open, mkdir, system } from 'fs';
import { connect } from 'ubus';
import { urldecode_params } from 'luci.http';

const DB_PATH = '/tmp/nikki/traffic.db';
const STATE_FILE = '/tmp/nikki/traffic_state.json';
const MAX_IP_STATS = 50;

// ========== 状态管理 ==========

function load_state() {
    var f = open(STATE_FILE, 'r');
    if (f) {
        var data = f.read('all');
        f.close();
        return json(data) || {};
    }
    return { uploadTotal: 0, downloadTotal: 0, timestamp: time(), last_cleanup: 0 };
}

function save_state(state) {
    var f = open(STATE_FILE, 'w');
    f.write(json(state, true));
    f.close();
}

// ========== 数据库初始化 ==========

function init_db() {
    mkdir('/tmp/nikki');
    
    // 使用系统命令初始化数据库
    system('sqlite3 ' + DB_PATH + ' "PRAGMA journal_mode=WAL; PRAGMA synchronous=OFF; PRAGMA cache_size=4096; PRAGMA temp_store=MEMORY;"');
    
    system('sqlite3 ' + DB_PATH + ' "CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload_total INTEGER DEFAULT 0, download_total INTEGER DEFAULT 0, updated_at INTEGER);"');
    system('sqlite3 ' + DB_PATH + ' "CREATE TABLE IF NOT EXISTS traffic_hourly (datetime TEXT PRIMARY KEY, upload INTEGER DEFAULT 0, download INTEGER DEFAULT 0, updated_at INTEGER);"');
    system('sqlite3 ' + DB_PATH + ' "CREATE TABLE IF NOT EXISTS traffic_ip_stats (id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL, hour INTEGER NOT NULL, ip_address TEXT NOT NULL, upload INTEGER DEFAULT 0, download INTEGER DEFAULT 0, UNIQUE(date, hour, ip_address));"');

    system('sqlite3 ' + DB_PATH + ' "CREATE INDEX IF NOT EXISTS idx_ip_date ON traffic_ip_stats(date, hour);"');
    system('sqlite3 ' + DB_PATH + ' "CREATE INDEX IF NOT EXISTS idx_hourly ON traffic_hourly(datetime);"');
}

// ========== 数据采集 ==========

function get_traffic_stats() {
    // 通过 ubus 调用 nikki 接口
    var ubus = connect();
    var res = ubus.call('nikki', 'traffic');
    
    if (res && res.uploadTotal != null) {
        return res;
    }
    
    // 降级：直接 HTTP API
    var http = require('http');
    try {
        var resp = http.get('http://127.0.0.1:9090/traffic');
        return json(resp.body);
    } catch (e) {
        warn('Failed to get traffic stats: ' + e);
        return { uploadTotal: 0, downloadTotal: 0, connections: [] };
    }
}

function calc_delta(current, last) {
    var up_delta = current.uploadTotal - last.uploadTotal;
    var down_delta = current.downloadTotal - last.downloadTotal;
    
    // 内核重启检测（累计值重置）
    if (up_delta < 0) up_delta = current.uploadTotal;
    if (down_delta < 0) down_delta = current.downloadTotal;
    
    return { upload: up_delta, download: down_delta };
}

function collect_traffic() {
    init_db();
    var stats = get_traffic_stats();
    var last = load_state();
    var now = time();
    
    // 时间回退检测
    if (now < last.timestamp) {
        warn('Time rollback detected: now=' + now + ', last=' + last.timestamp + '. Skipping collection.');
        return;
    }
    
    var delta = calc_delta(stats, last);
    var today = strftime('%Y-%m-%d', now);
    var this_hour = strftime('%Y-%m-%d %H:00', now);
    var current_hour = int(strftime('%H', now));
    
    // 使用系统命令执行SQL事务
    system('sqlite3 ' + DB_PATH + ' "BEGIN TRANSACTION; INSERT OR REPLACE INTO traffic_daily (date, upload_total, download_total, updated_at) VALUES (\'' + today + '\', COALESCE((SELECT upload_total FROM traffic_daily WHERE date=\'' + today + '\'), 0) + ' + delta.upload + ', COALESCE((SELECT download_total FROM traffic_daily WHERE date=\'' + today + '\'), 0) + ' + delta.download + ', ' + now + '); INSERT OR REPLACE INTO traffic_hourly (datetime, upload, download, updated_at) VALUES (\'' + this_hour + '\', COALESCE((SELECT upload FROM traffic_hourly WHERE datetime=\'' + this_hour + '\'), 0) + ' + delta.upload + ', COALESCE((SELECT download FROM traffic_hourly WHERE datetime=\'' + this_hour + '\'), 0) + ' + delta.download + ', ' + now + '); COMMIT;"');
    
    // IP 统计（内存聚合 + 限制数量）
    var ip_map = {};
    if (stats.connections && length(stats.connections) > 0) {
        for (var conn_idx in stats.connections) {
            var conn = stats.connections[conn_idx];
            var ip = conn.metadata && conn.metadata.sourceIP ? conn.metadata.sourceIP : 'unknown';
            if (!ip_map[ip]) {
                ip_map[ip] = { upload: 0, download: 0 };
            }
            ip_map[ip].upload += conn.upload || 0;
            ip_map[ip].download += conn.download || 0;
        }
    }
    
    // 排序并取前 N 个
    var ip_list = [];
    for (var ip_key in ip_map) {
        ip_list.push({
            ip: ip_key,
            up: ip_map[ip_key].upload,
            down: ip_map[ip_key].download,
            total: ip_map[ip_key].upload + ip_map[ip_key].download
        });
    }
    
    ip_list.sort(function(a, b) { return b.total - a.total; });
    if (length(ip_list) > MAX_IP_STATS) {
        ip_list = slice(ip_list, 0, MAX_IP_STATS);
    }
    
    // 批量写入 IP 统计
    for (var item_idx in ip_list) {
        var item = ip_list[item_idx];
        system('sqlite3 ' + DB_PATH + ' "INSERT OR REPLACE INTO traffic_ip_stats (date, hour, ip_address, upload, download) VALUES (\'' + today + '\', ' + current_hour + ', \'' + item.ip + '\', ' + item.up + ', ' + item.down + ')"');
    }
    
    // 更新状态
    last.uploadTotal = stats.uploadTotal;
    last.downloadTotal = stats.downloadTotal;
    last.timestamp = now;
    save_state(last);
    
    // 清理旧数据（每天一次）
    if (now - last.last_cleanup > 86400) {
        cleanup_old_data(today);
        last.last_cleanup = now;
        save_state(last);
    }
}

function cleanup_old_data(today) {
    var retain_days = 30;
    var retain_date = strftime('%Y-%m-%d', time() - (retain_days * 86400));
    
    system('sqlite3 ' + DB_PATH + ' "DELETE FROM traffic_daily WHERE date < \'' + retain_date + '\'; DELETE FROM traffic_hourly WHERE datetime < \'' + retain_date + '\'; DELETE FROM traffic_ip_stats WHERE date < \'' + retain_date + '\'; PRAGMA wal_checkpoint(TRUNCATE);"');
}

// ========== 数据查询 ==========

function get_stats(period, date) {
    var sql = '';
    
    if (period == 'day') {
        sql = 'SELECT datetime as time, upload, download, (upload + download) as total FROM traffic_hourly WHERE datetime LIKE \'' + date + '%\' ORDER BY datetime;';
    } else if (period == 'month') {
        sql = 'SELECT date as time, upload_total as upload, download_total as download, (upload_total + download_total) as total FROM traffic_daily WHERE date LIKE \'' + date + '%\' ORDER BY date;';
    } else if (period == 'year') {
        sql = 'SELECT strftime(\'%Y-%m\', date) as time, SUM(upload_total) as upload, SUM(download_total) as download, SUM(upload_total + download_total) as total FROM traffic_daily WHERE date LIKE \'' + date + '%\' GROUP BY strftime(\'%Y-%m\', date) ORDER BY time;';
    }
    
    var result = system('sqlite3 -json ' + DB_PATH + ' "' + sql + '"', true);
    if (result) {
        return json(result) || [];
    }
    return [];
}

function get_ip_stats(date, hour) {
    var sql = '';
    
    if (hour != null) {
        sql = 'SELECT ip_address, upload, download, (upload + download) as total FROM traffic_ip_stats WHERE date = \'' + date + '\' AND hour = ' + hour + ' ORDER BY total DESC LIMIT 100;';
    } else {
        sql = 'SELECT ip_address, SUM(upload) as upload, SUM(download) as download, SUM(upload + download) as total FROM traffic_ip_stats WHERE date = \'' + date + '\' GROUP BY ip_address ORDER BY total DESC LIMIT 100;';
    }
    
    var result = system('sqlite3 -json ' + DB_PATH + ' "' + sql + '"', true);
    if (result) {
        return json(result) || [];
    }
    return [];
}

function get_today_total() {
    var today = strftime('%Y-%m-%d', time());
    var result = system('sqlite3 -json ' + DB_PATH + ' "SELECT upload_total, download_total FROM traffic_daily WHERE date=\'' + today + '\'"', true);
    var data = json(result) || [];
    return data[0] || { upload_total: 0, download_total: 0 };
}

// ========== 数据导出（关机备份用）==========

function export_data() {
    var backup_path = '/etc/nikki/traffic.db.bak';
    mkdir('/etc/nikki');
    system('cp ' + DB_PATH + ' ' + backup_path);
    return backup_path;
}

function import_data() {
    var backup_path = '/etc/nikki/traffic.db.bak';
    if (stat(backup_path)) {
        system('cp ' + backup_path + ' ' + DB_PATH);
        return true;
    }
    return false;
}

// ========== CLI 入口 ==========

var args = ARGV;
if (length(args) < 1) {
    print('Usage: traffic.uc <command> [args...]');
    print('Commands: collect, stats, ip-stats, export, import');
    exit(1);
}

var cmd = args[0];

if (cmd == 'collect') {
    collect_traffic();
    print('Traffic collected.');
} else if (cmd == 'stats') {
    var period = args[1] || 'day';
    var date = args[2] || strftime('%Y-%m-%d', time());
    print(json(get_stats(period, date), true));
} else if (cmd == 'ip-stats') {
    var date = args[1] || strftime('%Y-%m-%d', time());
    var hour = args[2] ? int(args[2]) : null;
    print(json(get_ip_stats(date, hour), true));
} else if (cmd == 'export') {
    var path = export_data();
    print('Data exported to ' + path);
} else if (cmd == 'import') {
    if (import_data()) {
        print('Data imported successfully.');
    } else {
        print('Import failed.');
        exit(1);
    }
} else {
    print('Unknown command: ' + cmd);
    exit(1);
}