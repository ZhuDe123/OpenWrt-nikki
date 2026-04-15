#!/usr/bin/ucode
// /etc/nikki/ucode/traffic_collector.uc

import { system } from 'fs';

let interval = getenv('COLLECT_INTERVAL') || '30';
interval = int(interval);

while (true) {
    system('/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect');
    sleep(interval);
}