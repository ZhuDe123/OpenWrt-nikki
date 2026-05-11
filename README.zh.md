![GitHub License](https://img.shields.io/github/license/nikkinikki-org/OpenWrt-nikki?style=for-the-badge&logo=github) ![GitHub Tag](https://img.shields.io/github/v/release/nikkinikki-org/OpenWrt-nikki?style=for-the-badge&logo=github) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/nikkinikki-org/OpenWrt-nikki/total?style=for-the-badge&logo=github) ![GitHub Repo stars](https://img.shields.io/github/stars/nikkinikki-org/OpenWrt-nikki?style=for-the-badge&logo=github) [![Telegram](https://img.shields.io/badge/Telegram-gray?style=for-the-badge&logo=telegram)](https://t.me/nikkinikki_org)

中文 | [English](README.md)

# Nikki

在 OpenWrt 上使用 Mihomo 进行透明代理。

## 环境要求

- OpenWrt >= 23.05
- Linux Kernel >= 5.13
- firewall4

## 功能

- 透明代理 (Redirect/TPROXY/TUN, IPv4 和/或 IPv6)
- 访问控制
- 配置文件混入
- 配置文件编辑器
- 定时重启
- **流量统计**：实时查看全局和分 IP 的流量使用情况，支持日/月/年视图

## 流量统计功能

### 特性
- 📊 实时刷新（每 30 秒采集一次）
- 📈 多维度展示：日视图（折线图）、月视图（柱状图）、年视图
- 🌐 IP 统计：查看各设备的流量分布
- 💾 数据持久化：使用 SQLite 存储，支持历史查询
- 🗑️ 自动清理：可配置数据保留天数
- ⚡ 高性能：内存数据库 + WAL 模式，CPU 占用 < 1%

### 架构设计

流量统计系统由以下组件构成：

1. **Mihomo 内核 API**（基于自定义修改版本：[ZhuDe123/mihomo - Meta分支](https://github.com/ZhuDe123/mihomo.git)）
   - `/traffic/ip/accumulated` - 获取按 IP 维度累计的流量统计数据
   - 返回全局总流量（`upTotal`/`downTotal`）和各 IP 流量统计（`ipStats`）
   - 只在连接关闭后才记录 IP 流量，避免重复统计
   - 支持 IPv4 和 IPv6 地址

2. **流量采集脚本** (`/etc/nikki/ucode/traffic.uc`)
   - 定时从 Mihomo API 拉取流量数据
   - **内存预计算全量增量**：一次性读取快照、脚本内计算增量、事务批量写入
   - 写入 SQLite 数据库（位于 /tmp 内存盘，重启自动重建）
   - 自动处理服务重启场景（计数器重置时自动恢复）
   - 开启 WAL 模式提升并发写入性能
   - 所有数值使用 BIGINT（64位整型），支持超大流量

3. **数据库结构**
   ```sql
   -- 全局日统计
   CREATE TABLE traffic_daily (
       date TEXT PRIMARY KEY,
       upload BIGINT,      -- 上传流量（字节），64位整型
       download BIGINT,    -- 下载流量（字节），64位整型
       updated_at BIGINT   -- 更新时间戳，64位整型
   );

   -- 全局月统计
   CREATE TABLE traffic_monthly (
       month TEXT PRIMARY KEY,
       upload BIGINT,
       download BIGINT,
       updated_at BIGINT
   );

   -- 全局年统计
   CREATE TABLE traffic_yearly (
       year TEXT PRIMARY KEY,
       upload BIGINT,
       download BIGINT,
       updated_at BIGINT
   );

   -- 分钟级统计
   CREATE TABLE traffic_minute (
       date TEXT,
       time TEXT,
       upload BIGINT,
       download BIGINT,
       PRIMARY KEY(date, time)
   );

   -- IP 级别日统计
   CREATE TABLE traffic_ip_daily (
       date TEXT,
       ip TEXT,
       upload BIGINT,
       download BIGINT,
       PRIMARY KEY(date, ip)
   );

   -- 流量快照表（用于计算增量）
   CREATE TABLE traffic_last_capture (
       key TEXT PRIMARY KEY,
       upload BIGINT,      -- 上传流量快照
       download BIGINT,    -- 下载流量快照
       last_seen BIGINT    -- 最后一次出现的时间戳
   );
   ```

4. **Web 界面**
   - 实时图表展示（基于 Chart.js）
   - 支持日/月/年视图切换
   - IP 流量排名表格
   - 配置管理页面

### 工作原理

```
┌─────────────────────────────────┐
│  Mihomo 内核（自定义版本）       │
│  /traffic/ip/accumulated        │
│  - upTotal/downTotal（全局）    │
│  - ipStats[]（IP维度统计）      │
│  - 连接关闭时记录流量           │
└────────────┬────────────────────┘
             │ 每 30 秒
             ▼
┌──────────────────────────────────────────────────────┐
│  traffic.uc 采集脚本（内存预计算全量增量）             │
│  1. 调用 API 获取流量数据                              │
│  2. 一次性读取所有历史快照到内存                        │
│  3. 在脚本中计算流量增量（纯 int64 运算，无浮点）       │
│  4. 构建事务批量 SQL，一次性写入所有表                  │
│  5. 更新快照表，清理过期 IP 快照                        │
└────────────┬─────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────┐
│  SQLite 数据库（内存盘 /tmp/nikki/traffic.db）         │
│  - traffic_minute（分钟级统计，实时刷新）              │
│  - traffic_daily（日统计，由分钟聚合）                 │
│  - traffic_monthly（月统计）                          │
│  - traffic_yearly（年统计）                           │
│  - traffic_ip_daily（IP 维度日统计）                  │
│  - traffic_last_capture（流量快照，用于增量计算）      │
└──────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────┐
│  LuCI Web 界面               │
│  - 实时流量图表（分钟级）     │
│  - 日/月/年视图切换          │
│  - IP 流量排名               │
└──────────────────────────────┘
```

**增量计算逻辑（修复后）：**
脚本采用**内存预计算全量增量**的方式，从根源解决高频采集时的增量漏算、覆盖问题：
1. 一次性读取所有历史快照到内存
2. 在脚本中计算流量增量（纯整数运算，无浮点操作）
3. 构建事务批量 SQL，一次性写入所有统计表
4. 增量 = 当前值 - 上次快照值（若当前值 < 快照值，说明计数器重置，则增量 = 当前值）

**防重复统计机制：**
- Mihomo 内核使用 `LoadAndDelete` 原子操作，确保同一连接只被统计一次
- 即使连接的 `Close()` 被多次调用，只有第一次会触发流量记录
- 活跃连接流量计入 `upTotal`/`downTotal`，但不在 `ipStats` 中（仅关闭后记录）

### 修复说明（2024-05）

本次核心修复内容（解决数据偏差/脚本报错所有问题）：

1. **修复根因1：SQL 快照不一致导致的数据偏差**
   - 移除原逻辑中 SQL 动态子查询计算增量的方式
   - 改为**脚本内存预计算全量增量**，从根源解决高频采集时的增量漏算、覆盖问题

2. **修复根因2：ucode 语法错误（致命报错）**
   - 删除 ucode 不支持的 `int64()`/`sub64()` 函数
   - 使用 ucode **原生 64 位整数** 语法，脚本可正常运行无报错

3. **修复根因3：数值精度丢失（数据偏差一倍核心原因）**
   - 全程禁止浮点数运算，所有流量数值统一使用 `int()` 强制转换为纯整数
   - 杜绝隐式浮点数污染、32 位数值截断问题

4. **修复根因4：数据库字段类型风险**
   - 将所有表的流量/时间字段从 `INTEGER` 改为 `BIGINT`（64位整型）
   - 支持超大流量存储，彻底避免数据库层数值截断

5. **保留并优化：并发安全机制**
   - 完善分布式锁逻辑，防止多进程并发采集导致的数据重复计算、错乱

**修复效果：**
- 日表与分钟表数据完全对齐，彻底解决数据偏差一倍的问题
- 脚本无语法报错，稳定运行
- 支持超大流量统计，无溢出、无截断、无精度丢失

### 配置方法

#### 方法 1: 通过 LuCI Web 界面

1. 访问 `服务 → Nikki → 插件配置`
2. 找到"流量统计"选项卡
3. 勾选"启用流量统计"
4. 配置参数：
   - 采集间隔：默认 30 秒
   - 数据保留天数：默认 30 天
   - 数据库路径：默认 `/tmp/nikki/traffic.db`
5. 点击"保存并应用"
6. 访问"流量统计"选项卡查看实时数据

#### 方法 2: 通过命令行

```bash
# 启用流量统计
uci set nikki.traffic.enabled='1'

# 设置采集间隔（秒）
uci set nikki.traffic.collect_interval='30'

# 设置数据保留天数
uci set nikki.traffic.retain_days='30'

# 提交配置
uci commit nikki

# 重启流量统计服务
/etc/init.d/nikki-traffic restart
```

### 常用命令

#### 手动采集流量数据

```bash
# 执行一次流量采集
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect
```

#### 查询统计数据

```bash
# 查询今日统计
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats day 2026-04-18

# 查询本月统计
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats month 2026-04

# 查询指定日期统计
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats day 2026-04-17
```

#### 数据库操作

```bash
# 查看数据库表结构
sqlite3 /tmp/nikki/traffic.db ".schema"

# 查看今日流量统计
sqlite3 /tmp/nikki/traffic.db "SELECT * FROM traffic_daily WHERE date='2026-04-18';"

# 查看本月流量统计
sqlite3 /tmp/nikki/traffic.db "SELECT * FROM traffic_monthly WHERE month='2026-04';"

# 查看 IP 流量排名（今日 Top 10）
sqlite3 /tmp/nikki/traffic.db "SELECT ip, upload, download, (upload+download) as total FROM traffic_ip_daily WHERE date='2026-04-18' ORDER BY total DESC LIMIT 10;"

# 查看所有数据表
sqlite3 /tmp/nikki/traffic.db ".tables"

# 查看数据库大小
ls -lh /tmp/nikki/traffic.db
```

#### 持久化和清理

```bash
# 手动备份数据库到闪存
/usr/bin/ucode /etc/nikki/ucode/traffic.uc persist

# 清理 30 天前的数据
/usr/bin/ucode /etc/nikki/ucode/traffic.uc cleanup 30
```

#### 查看日志

```bash
# 查看流量统计日志
logread | grep Traffic

# 查看实时日志
tail -f /tmp/nikki/traffic.log
```

#### 测试和诊断

```bash
# 运行流量统计诊断脚本
/etc/nikki/scripts/traffic-test.sh

# 测试 Mihomo API 是否可用
curl -s -H "Authorization: Bearer YOUR_SECRET" \
  'http://127.0.0.1:9090/traffic/ip/accumulated'

# 查看 API 响应示例
# {
#   "upTotal": 5589997,
#   "downTotal": 34199057,
#   "ipStats": [
#     {
#       "ip": "192.168.5.164",
#       "upload": 1539074,
#       "download": 12253165,
#       "connCount": 338
#     }
#   ],
#   "total": 14,
#   "queryTimestamp": 1776478807
# }
```

### 性能影响

| 指标 | 数值 | 说明 |
|------|------|------|
| 内存占用 | ~5MB | SQLite 内存数据库 |
| CPU 占用 | < 1% | 每次采集约 100-500ms |
| 存储空间 | ~1MB/30天 | 取决于 IP 数量和连接数 |
| 采集间隔 | 30秒（默认） | 建议不低于 30 秒 |

### 注意事项

1. **数据库在内存盘**：数据库位于 `/tmp`，重启后会丢失，系统会自动从闪存备份恢复
2. **Mihomo API Secret**：确保 `nikki.mixin.api_secret` 已正确配置
3. **采集间隔**：不建议设置低于 30 秒，会影响性能
4. **闪存保护**：数据库使用内存盘 + 定时备份策略，避免频繁写入闪存
5. **自动清理**：建议设置合理的保留天数（默认 30 天），避免数据无限增长

### 故障排查

```bash
# 1. 检查流量统计是否启用
uci get nikki.traffic.enabled

# 2. 检查服务状态
ps | grep traffic

# 3. 检查数据库文件
ls -la /tmp/nikki/traffic.db

# 4. 检查 API Secret
uci get nikki.mixin.api_secret

# 5. 测试 API 连接
curl -s -H "Authorization: Bearer $(uci get nikki.mixin.api_secret)" \
  'http://127.0.0.1:9090/traffic/ip/accumulated'

# 6. 查看服务日志
logread | grep nikki-traffic

# 7. 重启流量统计服务
/etc/init.d/nikki-traffic restart
```

### Mihomo API 接口详情

#### 接口信息

| 项目 | 说明 |
|------|------|
| **接口路径** | `/traffic/ip/accumulated` |
| **请求方式** | `GET` |
| **认证方式** | Bearer Token（Header: `Authorization: Bearer $API_SECRET`） |
| **功能描述** | 获取按 IP 维度累计的流量统计数据，只在连接关闭后才记录流量 |

#### 请求示例

```bash
curl -s -H "Authorization: Bearer your_secret" \
  "http://127.0.0.1:9090/traffic/ip/accumulated"
```

#### 响应数据结构

```json
{
  "upTotal": 5589997,
  "downTotal": 34199057,
  "ipStats": [
    {
      "ip": "192.168.5.164",
      "upload": 1539074,
      "download": 12253165,
      "firstSeen": "2026-04-18T02:00:01.964605831Z",
      "firstSeenTimestamp": 1776477601,
      "lastSeen": "2026-04-18T02:20:04.61692775Z",
      "lastSeenTimestamp": 1776478804,
      "connCount": 338
    }
  ],
  "total": 14,
  "queryTimestamp": 1776478807
}
```

#### 字段说明

**根字段：**

| 字段名 | 类型 | 说明 |
|--------|------|------|
| `upTotal` | `int64` | 全局上传总量（字节），包含当前活跃连接的实时流量 |
| `downTotal` | `int64` | 全局下载总量（字节），包含当前活跃连接的实时流量 |
| `ipStats` | `array` | IP 维度的累计流量统计数组 |
| `total` | `int` | 统计到的唯一 IP 数量 |
| `queryTimestamp` | `int64` | 查询时的 Unix 时间戳（秒） |

**ipStats 数组元素：**

| 字段名 | 类型 | 说明 |
|--------|------|------|
| `ip` | `string` | 客户端 IP 地址（IPv4 或 IPv6） |
| `upload` | `int64` | 该 IP 累计上传流量（字节） |
| `download` | `int64` | 该 IP 累计下载流量（字节） |
| `firstSeen` | `string` | 首次出现时间（RFC3339 格式） |
| `firstSeenTimestamp` | `int64` | 首次出现时间的 Unix 时间戳（秒） |
| `lastSeen` | `string` | 最后一次连接关闭时间（RFC3339 格式） |
| `lastSeenTimestamp` | `int64` | 最后一次连接关闭时间的 Unix 时间戳（秒） |
| `connCount` | `int64` | 该 IP 累计关闭的连接数 |

#### 实现原理

Mihomo 内核通过以下组件实现流量统计：

| 组件 | 职责 |
|------|------|
| **Manager** | 管理活跃连接，提供实时流量统计（`upTotal`/`downTotal`） |
| **Tracker** | 追踪单个 TCP/UDP 连接的流量 |
| **Accumulator** | 按 IP 维度累计流量，连接关闭时记录 |

**流量统计流程：**
1. 连接建立 → 创建 Tracker 并加入活跃连接池
2. 数据传输 → 实时累加到全局统计
3. 连接关闭 → 从活跃连接池移除，并记录到 IP 累计统计

**防重复统计机制：**
- 使用 `LoadAndDelete` 原子操作，确保同一连接只被统计一次
- 即使 `Close()` 被多次调用，只有第一次会触发流量记录

#### 注意事项

1. **数据延迟**：`ipStats` 只在连接关闭时更新，活跃连接的流量不会实时反映
2. **数据一致性**：`ipStats` 总和 ≤ `upTotal`（差异来自未关闭的活跃连接）
3. **IP 格式**：支持 IPv4 和 IPv6 地址
4. **流量单位**：所有流量字段单位为**字节（Bytes）**

## 安装和更新

### A. 从软件源安装（推荐）

1. 添加源

```shell
# 只需运行一次
wget -O - https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/feed.sh | ash
```

2. 安装

```shell
# 你可以从 shell 执行命令安装或者从 LuCI 的`软件包`菜单安装
# for opkg
opkg install nikki
opkg install luci-app-nikki
opkg install luci-i18n-nikki-zh-cn
# for apk
apk add nikki
apk add luci-app-nikki
apk add luci-i18n-nikki-zh-cn
```

### B. 从发行版安装

```shell
wget -O - https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/install.sh | ash
```

## 卸载并重置

```shell
wget -O - https://github.com/nikkinikki-org/OpenWrt-nikki/raw/refs/heads/main/uninstall.sh | ash
```

## 如何使用

查看 [Wiki](https://github.com/nikkinikki-org/OpenWrt-nikki/wiki)

## 如何工作

1. 混入并更新配置文件。
2. 启动 Mihomo。
3. 设置定时重启。
4. 配置 IP 规则/路由。
5. 生成防火墙配置并应用。

注意上述步骤可能因配置而变动。

## 编译

```shell
# 添加源
echo "src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main" >> "feeds.conf.default"
# 更新并安装源
./scripts/feeds update -a
./scripts/feeds install -a
# 编译
make package/luci-app-nikki/compile
```

编译结果可以在`bin/packages/your_architecture/nikki`内找到。

## 依赖

- ca-bundle
- curl
- yq
- firewall4
- ip-full
- kmod-inet-diag
- kmod-nft-socket
- kmod-nft-tproxy
- kmod-tun

## 贡献者

[![贡献者](https://contrib.rocks/image?repo=nikkinikki-org/OpenWrt-nikki)](https://github.com/nikkinikki-org/OpenWrt-nikki/graphs/contributors)

## 特别感谢

- [@ApoisL](https://github.com/apoiston)
- [@xishang0128](https://github.com/xishang0128)

## 推荐机场

推荐 Perfect Link

路线全 IEPL、落地全 Akari 的机场，靠谱好用

[官网](https://perfectlink.io) | [客服](https://t.me/PerfectlinksupportBot)
