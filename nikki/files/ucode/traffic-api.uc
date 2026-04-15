#!/usr/bin/ucode
// /etc/nikki/ucode/traffic-api.uc

import { system } from 'fs';

// 通过 shell 脚本获取流量统计
function get_stats(period, date) {
    let cmd = `/etc/nikki/scripts/traffic-collect.sh stats ${period} ${date}`;
    let result = system(cmd, true);
    if (result) {
        return json(result) || {};
    }
    return {};
}

function get_ip_stats(date, hour) {
    let cmd = `/etc/nikki/scripts/traffic-collect.sh ip-stats ${date} ${hour || ''}`;
    let result = system(cmd, true);
    if (result) {
        return json(result) || {};
    }
    return {};
}

// ========== CLI 入口 ==========
let args = ARGV;
if (length(args) < 1) {
    print('Usage: traffic-api.uc <command> [args...]');
    print('Commands: stats, ip-stats');
    exit(1);
}

let cmd = args[0];

if (cmd == 'stats') {
    let period = args[1] || 'day';
    let date = args[2] || strftime('%Y-%m-%d', time());
    print(json(get_stats(period, date), true));
} else if (cmd == 'ip-stats') {
    let date = args[1] || strftime('%Y-%m-%d', time());
    let hour = args[2] || null;
    print(json(get_ip_stats(date, hour), true));
} else {
    print(`Unknown command: ${cmd}`);
    exit(1);
}