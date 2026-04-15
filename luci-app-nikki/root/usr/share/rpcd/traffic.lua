#!/usr/bin/lua

local sys = require "luci.sys"
local util = require "luci.util"
local http = require "luci.http"
local uci = require "luci.model.uci".cursor()

module("luci.rpc.traffic", package.seeall)

function traffic_stats()
    local period = http.formvalue("period") or "day"
    local date = http.formvalue("date") or os.date("%Y-%m-%d")
    
    -- 调用 ucode 脚本获取统计数据
    local result = sys.exec("/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats " .. period .. " " .. date)
    
    if result and result ~= "" then
        local stats = util.json_decode(result)
        if stats then
            -- 获取 IP 统计数据
            local ip_result = sys.exec("/usr/bin/ucode /etc/nikki/ucode/traffic.uc ip-stats " .. date)
            local ip_stats = util.json_decode(ip_result) or {}
            
            return {
                stats = stats,
                ip_stats = ip_stats,
                date = date,
                period = period
            }
        end
    end
    
    return {
        stats = {},
        ip_stats = {},
        date = date,
        period = period
    }
end