![GitHub License](https://img.shields.io/github/license/nikkinikki-org/OpenWrt-nikki?style=for-the-badge&logo=github) ![GitHub Tag](https://img.shields.io/github/v/release/nikkinikki-org/OpenWrt-nikki?style=for-the-badge&logo=github) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/nikkinikki-org/OpenWrt-nikki/total?style=for-the-badge&logo=github) ![GitHub Repo stars](https://img.shields.io/github/stars/nikkinikki-org/OpenWrt-nikki?style=for-the-badge&logo=github) [![Telegram](https://img.shields.io/badge/Telegram-gray?style=for-the-badge&logo=telegram)](https://t.me/nikkinikki_org)

English | [中文](README.zh.md)

# Nikki

Transparent Proxy with Mihomo on OpenWrt.

## Prerequisites

- OpenWrt >= 23.05
- Linux Kernel >= 5.13
- firewall4

## Feature

- Transparent Proxy (Redirect/TPROXY/TUN, IPv4 and/or IPv6)
- Access Control
- Profile Mixin
- Profile Editor
- Scheduled Restart
- **Traffic Statistics**: Real-time monitoring of global and per-IP traffic usage with daily/monthly/yearly views

## Traffic Statistics Feature

### Features
- 📊 Real-time refresh (collects every 30 seconds)
- 📈 Multi-dimensional display: Daily view (line chart), Monthly view (bar chart), Yearly view
- 🌐 IP Statistics: View traffic distribution for each device
- 💾 Data persistence: SQLite storage with historical query support
- 🗑️ Auto cleanup: Configurable data retention days
- ⚡ High performance: Memory database + WAL mode, CPU usage < 1%

### Architecture

The traffic statistics system consists of:

1. **Mihomo Kernel API**
   - `/traffic/latest` - Get global cumulative traffic (upload/download totals)
   - `/traffic/closed` - Get detailed traffic data for closed connections
   - Automatically records IP and traffic info when connections close

2. **Traffic Collection Script** (`/etc/nikki/ucode/traffic.uc`)
   - Periodically pulls traffic data from Mihomo API
   - **Memory pre-calculation of full deltas**: reads all snapshots at once, calculates deltas in script, batch writes via transaction
   - Writes to SQLite database (in /tmp RAM disk, auto-rebuilt on restart)
   - Automatically handles service restart scenarios (auto-recovery on counter reset)
   - Enables WAL mode for better concurrent write performance
   - All numeric fields use BIGINT (64-bit integer) for large traffic support

3. **Database Structure**
   ```sql
   -- Global daily statistics
   CREATE TABLE traffic_daily (
       date TEXT PRIMARY KEY,
       upload BIGINT,      -- Upload traffic (bytes), 64-bit integer
       download BIGINT,    -- Download traffic (bytes), 64-bit integer
       updated_at BIGINT   -- Update timestamp, 64-bit integer
   );

   -- Global monthly statistics
   CREATE TABLE traffic_monthly (
       month TEXT PRIMARY KEY,
       upload BIGINT,
       download BIGINT,
       updated_at BIGINT
   );

   -- Global yearly statistics
   CREATE TABLE traffic_yearly (
       year TEXT PRIMARY KEY,
       upload BIGINT,
       download BIGINT,
       updated_at BIGINT
   );

   -- Minute-level statistics
   CREATE TABLE traffic_minute (
       date TEXT,
       time TEXT,
       upload BIGINT,
       download BIGINT,
       PRIMARY KEY(date, time)
   );

   -- IP-level daily statistics
   CREATE TABLE traffic_ip_daily (
       date TEXT,
       ip TEXT,
       upload BIGINT,
       download BIGINT,
       PRIMARY KEY(date, ip)
   );

   -- Traffic snapshot table (for incremental calculation)
   CREATE TABLE traffic_last_capture (
       key TEXT PRIMARY KEY,
       upload BIGINT,      -- Upload traffic snapshot
       download BIGINT,    -- Download traffic snapshot
       last_seen BIGINT    -- Last seen timestamp
   );
   ```

4. **Web Interface**
   - Real-time chart display (based on Chart.js)
   - Support daily/monthly/yearly view switching
   - IP traffic ranking table
   - Configuration management page

### How It Works

```
┌─────────────────────────────────┐
│  Mihomo Kernel (Custom Version) │
│  /traffic/ip/accumulated        │
│  - upTotal/downTotal (Global)   │
│  - ipStats[] (IP Statistics)    │
│  - Records on connection close  │
└────────────┬────────────────────┘
             │ Every 30 seconds
             ▼
┌──────────────────────────────────────────────────────┐
│  traffic.uc Script (In-Memory Delta Pre-calculation) │
│  1. Call API to get traffic data                     │
│  2. Read all historical snapshots into memory        │
│  3. Calculate deltas in script (pure int64, no float)│
│  4. Build transaction batch SQL, write all tables    │
│  5. Update snapshot table, clean expired IP snapshots│
└────────────┬─────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────┐
│  SQLite Database (RAM Disk /tmp/nikki/traffic.db)    │
│  - traffic_minute (Minute-level, real-time)          │
│  - traffic_daily (Daily, aggregated from minutes)    │
│  - traffic_monthly (Monthly)                         │
│  - traffic_yearly (Yearly)                           │
│  - traffic_ip_daily (IP-level daily)                 │
│  - traffic_last_capture (Snapshots for delta calc)   │
└──────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────┐
│  LuCI Web Interface          │
│  - Real-time charts (minute) │
│  - Day/Month/Year view       │
│  - IP traffic ranking        │
└──────────────────────────────┘
```

**Incremental Calculation Logic (Fixed):**
The script uses **in-memory pre-calculation of full deltas**, solving delta calculation issues at high collection frequency:
1. Reads all historical snapshots into memory at once
2. Calculates traffic deltas in script (pure int64 operations, no floating point)
3. Builds transaction batch SQL to write all tables at once
4. Delta = Current value - Last snapshot value (if current < snapshot, counter reset, delta = current value)

### Fix Notes (2024-05)

Core fixes (resolving data deviation / script errors):

1. **Fix Root Cause 1: Data deviation caused by SQL snapshot inconsistency**
   - Removed SQL dynamic subquery delta calculation
   - Changed to **in-memory pre-calculation of full deltas** to solve incremental miss/overwrite issues

2. **Fix Root Cause 2: ucode syntax errors (fatal)**
   - Removed unsupported `int64()`/`sub64()` functions
   - Use ucode **native 64-bit integer** syntax for error-free execution

3. **Fix Root Cause 3: Numeric precision loss (core cause of 1x deviation)**
   - No floating point operations allowed, all traffic values use `int()` for pure integer conversion
   - Eliminates implicit floating point pollution and 32-bit truncation

4. **Fix Root Cause 4: Database field type risk**
   - Changed all traffic/timestamp fields from `INTEGER` to `BIGINT` (64-bit integer)
   - Supports large traffic storage, eliminates database-level truncation

5. **Retained & optimized: Concurrency safety**
   - Improved distributed lock logic to prevent data duplication/chaos from concurrent collection

**Fix Results:**
- Daily and minute tables are now fully aligned, completely solving the 1x data deviation issue
- Script runs without syntax errors, stable operation
- Supports large traffic statistics without overflow, truncation, or precision loss

### Configuration

#### Method 1: Via LuCI Web Interface

1. Navigate to `Services → Nikki → Plugin Configuration`
2. Find the "Traffic Statistics" tab
3. Check "Enable Traffic Statistics"
4. Configure parameters:
   - Collection interval: Default 30 seconds
   - Data retention days: Default 30 days
   - Database path: Default `/tmp/nikki/traffic.db`
5. Click "Save & Apply"
6. Access the "Traffic Statistics" tab to view real-time data

#### Method 2: Via Command Line

```bash
# Enable traffic statistics
uci set nikki.traffic.enabled='1'

# Set collection interval (seconds)
uci set nikki.traffic.collect_interval='30'

# Set data retention days
uci set nikki.traffic.retain_days='30'

# Commit configuration
uci commit nikki

# Restart traffic statistics service
/etc/init.d/nikki-traffic restart
```

### Common Commands

#### Manually Collect Traffic Data

```bash
# Execute one traffic collection
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect
```

#### Query Statistics

```bash
# Query today's statistics
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats day 2026-04-18

# Query this month's statistics
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats month 2026-04

# Query specific date statistics
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats day 2026-04-17
```

#### Database Operations

```bash
# View database schema
sqlite3 /tmp/nikki/traffic.db ".schema"

# View today's traffic statistics
sqlite3 /tmp/nikki/traffic.db "SELECT * FROM traffic_daily WHERE date='2026-04-18';"

# View this month's traffic statistics
sqlite3 /tmp/nikki/traffic.db "SELECT * FROM traffic_monthly WHERE month='2026-04';"

# View IP traffic ranking (Today's Top 10)
sqlite3 /tmp/nikki/traffic.db "SELECT ip, upload, download, (upload+download) as total FROM traffic_ip_daily WHERE date='2026-04-18' ORDER BY total DESC LIMIT 10;"

# View all tables
sqlite3 /tmp/nikki/traffic.db ".tables"

# View database size
ls -lh /tmp/nikki/traffic.db
```

#### Persistence and Cleanup

```bash
# Manually backup database to flash
/usr/bin/ucode /etc/nikki/ucode/traffic.uc persist

# Clean up data older than 30 days
/usr/bin/ucode /etc/nikki/ucode/traffic.uc cleanup 30
```

#### View Logs

```bash
# View traffic statistics logs
logread | grep Traffic

# View real-time logs
tail -f /tmp/nikki/traffic.log
```

#### Testing and Diagnostics

```bash
# Run traffic statistics diagnostic script
/etc/nikki/scripts/traffic-test.sh

# Test if Mihomo API is available
curl -s -H "Authorization: Bearer YOUR_SECRET" 'http://127.0.0.1:9090/traffic/latest'

# Test closed connections API
curl -s -H "Authorization: Bearer YOUR_SECRET" 'http://127.0.0.1:9090/traffic/closed'
```

### Performance Impact

| Metric | Value | Description |
|--------|-------|-------------|
| Memory Usage | ~5MB | SQLite memory database |
| CPU Usage | < 1% | About 100-500ms per collection |
| Storage Space | ~1MB/30days | Depends on IP count and connections |
| Collection Interval | 30s (default) | Not recommended below 30 seconds |

### Notes

1. **Database in RAM disk**: Database is located in `/tmp`, will be lost on restart, system automatically restores from flash backup
2. **Mihomo API Secret**: Ensure `nikki.mixin.api_secret` is correctly configured
3. **Collection interval**: Not recommended to set below 30 seconds, will affect performance
4. **Flash protection**: Database uses RAM disk + periodic backup strategy to avoid frequent flash writes
5. **Auto cleanup**: Recommended to set reasonable retention days (default 30 days) to prevent unlimited data growth

### Troubleshooting

```bash
# 1. Check if traffic statistics is enabled
uci get nikki.traffic.enabled

# 2. Check service status
ps | grep traffic

# 3. Check database file
ls -la /tmp/nikki/traffic.db

# 4. Check API Secret
uci get nikki.mixin.api_secret

# 5. Test API connection
curl -s -H "Authorization: Bearer $(uci get nikki.mixin.api_secret)" \
  'http://127.0.0.1:9090/traffic/latest'

# 6. View service logs
logread | grep nikki-traffic

# 7. Restart traffic statistics service
/etc/init.d/nikki-traffic restart
```

## Install & Update

### A. Install From Feed (Recommended)

1. Add Feed

```shell
# only needs to be run once
wget -O - https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/feed.sh | ash
```

2. Install

```shell
# you can install from shell or `Software` menu in LuCI
# for opkg
opkg install nikki
opkg install luci-app-nikki
opkg install luci-i18n-nikki-zh-cn
# for apk
apk add nikki
apk add luci-app-nikki
apk add luci-i18n-nikki-zh-cn
```

### B. Install From Release

```shell
wget -O - https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/install.sh | ash
```

## Uninstall & Reset

```shell
wget -O - https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/uninstall.sh | ash
```

## How To Use

See [Wiki](https://github.com/nikkinikki-org/OpenWrt-nikki/wiki)

## How does it work

1. Mixin and Update profile.
2. Run mihomo.
3. Set scheduled restart.
4. Set ip rule/route
5. Generate nftables and apply it.

Note that the steps above may change base on config.

## Compilation

```shell
# add feed
echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> "feeds.conf.default"
# update & install feeds
./scripts/feeds update -a
./scripts/feeds install -a
# make package
make package/luci-app-nikki/compile
```

The package files will be found under `bin/packages/your_architecture/nikki`.

## Dependencies

- ca-bundle
- curl
- yq
- firewall4
- ip-full
- kmod-inet-diag
- kmod-nft-socket
- kmod-nft-tproxy
- kmod-tun

## Contributors

[![Contributors](https://contrib.rocks/image?repo=nikkinikki-org/OpenWrt-nikki)](https://github.com/nikkinikki-org/OpenWrt-nikki/graphs/contributors)

## Special Thanks

- [@ApoisL](https://github.com/apoiston)
- [@xishang0128](https://github.com/xishang0128)

## Recommended Proxy Provider

Perfect Link is recommended

All route on IEPL, All exit node at Akari, reliable and easy to use

[Official Website](https://perfectlink.io) | [Customer Service](https://t.me/PerfectlinksupportBot)
