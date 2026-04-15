# 流量统计系统 - 完整部署指南

## 📦 系统组成

### 1. mihomo 内核修改
- ✅ `/traffic/latest` - 非流式流量 API
- ✅ `/traffic/closed` - 已关闭连接 API
- ✅ 连接关闭时自动记录

### 2. 流量统计脚本
- ✅ `/etc/nikki/ucode/traffic.uc`
- ✅ 支持全局总量 + IP 维度统计
- ✅ 支持日/月统计
- ✅ 自动备份到 flash

### 3. Web 界面
- ✅ 流量统计展示页面
- ✅ 实时图表显示
- ✅ IP 流量排名
- ✅ 配置管理页面

---

## 🚀 部署步骤

### 步骤 1: 编译并部署 mihomo

```bash
# 在电脑上编译
cd /home/zhudeshuai/mihomo
export PATH=$PATH:/home/zhudeshuai/go/bin
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -v -tags "with_gvisor" -trimpath \
  -ldflags="-extldflags --static -w -s -buildid=" -o /tmp/mihomo-traffic

# 上传到路由器
scp /tmp/mihomo-traffic root@路由器IP:/tmp/mihomo-new

# 在路由器上
ssh root@路由器IP
mv /tmp/mihomo-new /usr/bin/mihomo
chmod +x /usr/bin/mihomo
/etc/init.d/nikki restart
```

### 步骤 2: 部署流量统计脚本

```bash
# 上传脚本
scp /home/zhudeshuai/OpenWrt-nikki/nikki/files/ucode/traffic.uc root@路由器IP:/tmp/traffic.uc

# 在路由器上
ssh root@路由器IP
mv /tmp/traffic.uc /etc/nikki/ucode/traffic.uc
chmod +x /etc/nikki/ucode/traffic.uc

# 初始化数据库
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect

# 验证
sqlite3 /tmp/nikki/traffic.db ".schema"
sqlite3 /tmp/nikki/traffic.db "SELECT * FROM traffic_daily;"
```

### 步骤 3: 配置定时采集

```bash
# 在路由器上编辑 crontab
cat >> /etc/crontabs/root << 'EOF'

# 流量统计 - 每 30 秒采集一次
*/1 * * * * /usr/bin/ucode /etc/nikki/ucode/traffic.uc collect
*/1 * * * * sleep 30; /usr/bin/ucode /etc/nikki/ucode/traffic.uc collect

# 每小时备份到 flash
0 * * * * /usr/bin/ucode /etc/nikki/ucode/traffic.uc persist

# 每天凌晨 3 点清理 30 天前的数据
0 3 * * * /usr/bin/ucode /etc/nikki/ucode/traffic.uc cleanup 30
EOF

# 重启 cron
/etc/init.d/cron restart

# 验证 crontab
crontab -l
```

### 步骤 4: 启用流量统计（可选）

```bash
# 通过 UCI 配置
uci set nikki.traffic.enabled='1'
uci set nikki.traffic.collect_interval='30'
uci set nikki.traffic.retain_days='30'
uci set nikki.traffic.auto_backup='1'
uci commit nikki

# 或者通过 Web 界面配置
# 访问：http://路由器IP/cgi-bin/luci/admin/services/nikki/traffic-config
```

---

## 📊 使用方法

### 命令行查询

```bash
# 查询今日统计
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats day 2026-04-15

# 查询本月统计
/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats month 2026-04

# 查询历史统计（最近 7 天）
/usr/bin/ucode /etc/nikki/ucode/traffic.uc history 7

# 清理旧数据
/usr/bin/ucode /etc/nikki/ucode/traffic.uc cleanup 30
```

### Web 界面

访问：`http://路由器IP/cgi-bin/luci/admin/services/nikki/traffic`

功能：
- ✅ 实时流量图表
- ✅ IP 流量排名
- ✅ 日/月视图切换
- ✅ 自动刷新（5 秒间隔）

---

## 🔧 API 使用

### 1. 获取全局总量

```bash
curl -s -H "Authorization: Bearer SECRET" \
  'http://127.0.0.1:9090/traffic/latest'

# 返回：
# {"up":0,"down":0,"upTotal":17653,"downTotal":5793}
```

### 2. 获取已关闭连接

```bash
curl -s -H "Authorization: Bearer SECRET" \
  'http://127.0.0.1:9090/traffic/closed'

# 返回：
# {"closedConnections":[{...},{...}]}
```

### 3. 获取活跃连接

```bash
curl -s -m 2 -H "Authorization: Bearer SECRET" \
  'http://127.0.0.1:9090/connections'

# 返回：
# {"connections":[{...},{...}]}
```

---

## 📈 数据库结构

```sql
-- 日统计表
CREATE TABLE traffic_daily (
    date TEXT PRIMARY KEY,
    upload INTEGER,
    download INTEGER,
    updated_at INTEGER
);

-- 月统计表
CREATE TABLE traffic_monthly (
    month TEXT PRIMARY KEY,
    upload INTEGER,
    download INTEGER,
    updated_at INTEGER
);

-- IP 日统计
CREATE TABLE traffic_ip_daily (
    date TEXT,
    ip TEXT,
    upload INTEGER,
    download INTEGER,
    PRIMARY KEY(date, ip)
);

-- 索引
CREATE INDEX idx_ip_date ON traffic_ip_daily(date);
CREATE INDEX idx_daily_date ON traffic_daily(date);
CREATE INDEX idx_monthly_month ON traffic_monthly(month);
```

---

## ⚙️ 配置选项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `enabled` | 0 | 是否启用流量统计 |
| `collect_interval` | 30 | 采集间隔（秒） |
| `retain_days` | 30 | 数据保留天数 |
| `db_path` | /tmp/nikki/traffic.db | 数据库路径 |
| `auto_backup` | 1 | 自动备份到 flash |

---

## 🔍 故障排查

### 问题 1: 数据库不存在

```bash
# 手动运行一次采集
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect

# 检查数据库
ls -la /tmp/nikki/traffic.db
sqlite3 /tmp/nikki/traffic.db ".schema"
```

### 问题 2: API 无法访问

```bash
# 检查 mihomo 是否运行
ps | grep mihomo

# 检查 API secret
uci get nikki.api_secret

# 测试 API
curl -s -H "Authorization: Bearer SECRET" 'http://127.0.0.1:9090/traffic/latest'
```

### 问题 3: crontab 不执行

```bash
# 检查 cron 服务
/etc/init.d/cron status

# 查看日志
logread | grep CRON

# 手动执行测试
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect
```

---

## 📊 性能优化建议

### 家庭网络 (< 50 设备)
- 采集间隔：30 秒
- 限制 /connections: 50KB
- 内存占用：< 5MB

### 企业网络 (> 100 设备)
- 采集间隔：60-120 秒
- 限制 /connections: 20KB
- 只用 /traffic/latest + /traffic/closed
- 内存占用：< 10MB

---

## 🎯 功能清单

| 功能 | 状态 | 说明 |
|------|------|------|
| 全局流量统计 | ✅ | 上传/下载总量 |
| 按 IP 统计 | ✅ | 各设备流量 |
| 日统计 | ✅ | 每日流量汇总 |
| 月统计 | ✅ | 每月流量汇总 |
| Web 界面 | ✅ | 图表展示 |
| 配置管理 | ✅ | Web 配置 |
| 自动备份 | ✅ | 每小时备份 |
| 自动清理 | ✅ | 30 天自动清理 |
| 并发保护 | ✅ | 锁文件机制 |
| 错误处理 | ✅ | JSON 解析容错 |

---

## 📝 更新日志

### v1.0.0 (2026-04-15)
- ✅ 新增 /traffic/latest API
- ✅ 新增 /traffic/closed API
- ✅ 完整流量统计系统
- ✅ Web 界面展示
- ✅ 配置管理页面
- ✅ 性能优化

---

## 💡 常见问题

**Q: 为什么 /connections 要限制数据量？**  
A: 连接数多时响应很大（几 MB），会影响性能和内存。

**Q: 可以只统计总量，不统计 IP 吗？**  
A: 可以，修改脚本不调用 /connections 即可。

**Q: 数据库在 /tmp，重启会丢失吗？**  
A: 有自动备份，重启后会从 /etc/nikki/traffic.db.bak 恢复。

**Q: 如何关闭流量统计？**  
A: Web 界面关闭或执行 `uci set nikki.traffic.enabled='0'`。

---

## 📞 支持

遇到问题请查看：
1. 日志：`logread | grep Traffic`
2. 数据库：`sqlite3 /tmp/nikki/traffic.db ".tables"`
3. 配置：`uci show nikki.traffic`
