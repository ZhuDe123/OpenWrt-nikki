# 流量统计测试脚本使用说明

## 概述

`traffic-test.sh` 是一个完整的诊断脚本，用于快速判断 Nikki 流量统计功能是否正常工作。

## 安装位置

脚本会安装到路由器的 `/etc/nikki/scripts/traffic-test.sh`

## 使用方法

### SSH 登录路由器后执行

```bash
# 执行完整诊断
/etc/nikki/scripts/traffic-test.sh

# 或者使用简写
nikki-traffic-test
```

## 诊断内容

测试脚本会检查以下内容：

### 1. 基础文件完整性
- ✓ traffic.uc 脚本是否存在
- ✓ traffic-collect.sh 脚本是否存在
- ✓ traffic.lua RPC 接口是否存在

### 2. UCI 配置检查
- ✓ nikki.traffic 配置节是否存在
- ✓ 流量统计是否启用 (enabled)
- ✓ 采集间隔配置 (collect_interval)
- ✓ 数据库路径配置 (db_path)

### 3. API Secret 配置
- ✓ Mihomo API Secret 是否配置
- ✓ traffic.uc 能否正确读取 API Secret

### 4. SQLite 数据库状态
- ✓ 数据库文件是否存在
- ✓ 数据库是否可正常访问
- ✓ 表结构是否完整 (traffic_daily, traffic_ip_daily)
- ✓ 是否有统计数据

### 5. Mihomo API 连接测试
- ✓ API 监听地址配置
- ✓ API 是否可访问 (/version)
- ✓ 流量 API 是否正常 (/traffic/latest)
- ✓ IP 流量 API 是否正常 (/traffic/ip)
- ✓ 显示当前流量数据

### 6. traffic.uc 脚本执行测试
- ✓ collect 命令是否可执行
- ✓ stats 命令是否可执行
- ✓ 返回的统计数据格式

### 7. 定时任务检查
- ✓ crontab 中是否配置了流量统计任务
- ✓ nikki-traffic 服务是否存在
- ✓ 服务是否已启用

## 输出说明

脚本使用颜色标识不同的检查结果：

- **绿色 [OK]**: 检查通过
- **红色 [FAIL]**: 检查失败，需要修复
- **黄色 [WARN]**: 警告，可能影响功能但不是致命问题
- **蓝色 [INFO]**: 信息提示

## 诊断结果

脚本最后会汇总所有检查结果：

```
========================================
   诊断结果汇总
========================================
通过: XX
失败: XX
警告: XX

✓ 流量统计功能正常
或
✗ 流量统计功能存在故障，请根据上述错误信息进行修复
```

## 常见问题排查

### 1. API Secret 不匹配

如果显示 `traffic.uc 无法读取 API Secret`，请检查：

```bash
# 查看当前配置的 API Secret
uci get nikki.mixin.api_secret

# 如果没有，需要重新生成或设置
uci set nikki.mixin.api_secret=$(awk 'BEGIN{srand(); printf "%06d", int(rand() * 1000000)}')
uci commit nikki
```

### 2. Mihomo API 无法连接

如果显示 `无法连接到 Mihomo API`，请检查：

```bash
# 检查 nikki 服务状态
/etc/init.d/nikki status

# 查看 API 监听配置
uci get nikki.mixin.api_listen

# 重启 nikki 服务
/etc/init.d/nikki restart
```

### 3. 数据库不存在

如果显示 `数据库文件不存在`，这是正常的，第一次运行 collect 命令后会创建：

```bash
# 手动执行一次采集
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect

# 或者使用脚本
/etc/nikki/scripts/traffic-collect.sh collect
```

### 4. 流量统计未启用

如果显示 `流量统计未启用`，请启用它：

```bash
uci set nikki.traffic.enabled='1'
uci commit nikki
/etc/init.d/nikki-traffic restart
```

## 快速修复流程

如果诊断发现问题，可以按以下流程修复：

```bash
# 1. 确保配置正确
uci set nikki.traffic.enabled='1'
uci set nikki.traffic.collect_interval='30'
uci set nikki.traffic.db_path='/tmp/nikki/traffic.db'
uci commit nikki

# 2. 重启服务
/etc/init.d/nikki restart
/etc/init.d/nikki-traffic restart

# 3. 手动采集一次数据
/usr/bin/ucode /etc/nikki/ucode/traffic.uc collect

# 4. 再次运行诊断
/etc/nikki/scripts/traffic-test.sh
```

## 编译时打包

测试脚本会在编译时自动打包到 `nikki` ipk 包中：

```makefile
# nikki/Makefile
$(INSTALL_BIN) $(CURDIR)/files/scripts/traffic-test.sh $(1)/etc/nikki/scripts/traffic-test.sh
```

## 版本历史

- v1.0 (2026-04-16): 初始版本，包含完整的诊断功能
