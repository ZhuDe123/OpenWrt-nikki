#!/usr/bin/lua
-- LuCI RPC API for traffic statistics
-- Fixed: Command injection prevention, parameter validation

local util = require "luci.util"
local sys = require "luci.sys"
local http = require "luci.http"

module("luci.rpc.traffic", package.seeall)

function traffic_stats()
    -- 1. 参数验证 (白名单)
    local period = http.formvalue("period") or "day"
    if period ~= "day" and period ~= "month" and period ~= "year" then
        period = "day"
    end
    
    local date = http.formvalue("date") or os.date("%Y-%m-%d")
    -- 严格的日期格式校验
    if not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
        date = os.date("%Y-%m-%d")
    end

    -- 2. 执行安全转义后的命令
    local cmd = string.format("/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats %s %s 2>&1", 
        util.shellquote(period), 
        util.shellquote(date))
    
    local raw_data = util.exec(cmd)

    -- 3. 输出
    http.prepare_content("application/json")
    http.write(raw_data or "{\"error\": \"no data\"}")
end
