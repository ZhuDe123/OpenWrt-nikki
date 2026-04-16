#!/usr/bin/lua
-- LuCI RPC API for traffic statistics
-- 支持日/月统计，带错误处理

local util = require "luci.util"
local http = require "luci.http"
local json = require "luci.jsonc"
local uci = require "luci.model.uci".cursor()

module("luci.rpc.traffic", package.seeall)

local API_SECRET = uci:get_first("nikki", "mixin", "api_secret", "")

function traffic_stats()
    local period = http.formvalue("period") or "day"
    local date = http.formvalue("date") or os.date("%Y-%m-%d")
    
    -- 验证 period
    if period ~= "day" and period ~= "month" then
        period = "day"
    end
    
    -- 验证 date 格式
    if period == "day" and not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
        date = os.date("%Y-%m-%d")
    elseif period == "month" and not date:match("^%d%d%d%d%-%d%d$") then
        date = os.date("%Y-%m")
    end
    
    -- 调用 ucode 脚本获取数据
    local cmd = string.format("/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats %s %s 2>&1",
        util.shellquote(period),
        util.shellquote(date))
    
    local raw_data = util.exec(cmd)
    
    http.prepare_content("application/json")
    http.write(raw_data or "{\"error\": \"no data\"}")
end
