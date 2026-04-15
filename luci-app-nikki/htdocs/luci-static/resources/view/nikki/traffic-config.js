local m, s, o

m = Map("nikki", "Traffic Statistics Configuration",
    "Configure traffic statistics collection and display")

s = m:section(TypedSection, "traffic", "Traffic Statistics Settings")
s.anonymous = true
s.addremove = false

-- 启用/禁用开关
o = s:option(Flag, "enabled", "Enable Traffic Statistics",
    "Enable or disable traffic statistics collection")
o.default = 0
o.rmempty = false

-- 采集间隔
o = s:option(Value, "collect_interval", "Collection Interval (seconds)",
    "How often to collect traffic data (30-300 seconds recommended)")
o.datatype = "uinteger"
o.default = "30"
o.placeholder = "30"
o.rmempty = false

-- 数据保留天数
o = s:option(Value, "retain_days", "Data Retention (days)",
    "How many days of data to keep")
o.datatype = "uinteger"
o.default = "30"
o.placeholder = "30"
o.rmempty = false

-- 数据库路径
o = s:option(Value, "db_path", "Database Path",
    "Path to store traffic statistics database")
o.default = "/tmp/nikki/traffic.db"
o.rmempty = false

-- 自动备份
o = s:option(Flag, "auto_backup", "Auto Backup",
    "Automatically backup database to flash storage")
o.default = 1
o.rmempty = false

return m
