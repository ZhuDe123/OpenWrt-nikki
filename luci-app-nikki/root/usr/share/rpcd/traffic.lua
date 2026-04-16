#!/usr/bin/lua
-- LuCI RPC API for traffic statistics
-- 优化：直接调用 sqlite3，跳过 ucode 中间层

local util = require "luci.util"
local http = require "luci.http"
local json = require "luci.jsonc"

module("luci.rpc.traffic", package.seeall)

local DB_PATH = '/tmp/nikki/traffic.db'

-- 执行 sqlite3 查询并返回解析后的数据
local function sqlite_query(sql)
    local cmd = string.format("sqlite3 -json %s %s 2>/dev/null",
        util.shellquote(DB_PATH),
        util.shellquote(sql))
    local result = util.exec(cmd)
    if result and result ~= "" then
        local parsed = json.parse(result)
        if parsed then
            return parsed
        end
    end
    return {}
end

function traffic_stats()
    local period = http.formvalue("period") or "day"
    local date_val = http.formvalue("date") or ""

    -- 验证 period
    if period ~= "day" and period ~= "month" and period ~= "year" then
        period = "day"
    end

    -- 默认日期
    if date_val == "" then
        if period == "day" then
            date_val = os.date("%Y-%m-%d")
        elseif period == "month" then
            date_val = os.date("%Y-%m")
        else
            date_val = os.date("%Y")
        end
    end

    local result = {}

    if period == "year" then
        -- 年度视图：查询 12 个月
        result.monthly = sqlite_query(
            string.format("SELECT month, upload, download FROM traffic_monthly WHERE month LIKE '%s-%%' ORDER BY month;",
                date_val))
        result.yearly = sqlite_query(
            string.format("SELECT year, upload, download FROM traffic_yearly WHERE year = '%s';",
                date_val))

    elseif period == "month" then
        -- 月份视图：查询每天
        result.daily = sqlite_query(
            string.format("SELECT date, upload, download FROM traffic_daily WHERE date LIKE '%s-%%' ORDER BY date;",
                date_val))
        result.monthly = sqlite_query(
            string.format("SELECT month, upload, download FROM traffic_monthly WHERE month = '%s';",
                date_val))

    else -- period == "day"
        -- 日视图：查询分钟级数据
        local now_time = os.date("%H:%M")
        result.minute = sqlite_query(
            string.format("SELECT time, upload, download FROM traffic_minute WHERE date = '%s' AND time <= '%s' ORDER BY time;",
                date_val, now_time))
        result.global = sqlite_query(
            string.format("SELECT date, upload, download, updated_at FROM traffic_daily WHERE date = '%s';",
                date_val))
        result.ip = sqlite_query(
            string.format("SELECT ip, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 50;",
                date_val))
    end

    http.prepare_content("application/json")
    http.write(json.stringify(result))
end
