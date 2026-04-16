module("luci.controller.nikki", package.seeall)

function index()
    -- 流量统计 API 端点 - 用于 JavaScript 前端请求
    entry({"admin", "services", "nikki", "api", "traffic_stats"}, call("traffic_stats_action"), nil).leaf = true
end

function traffic_stats_action()
    local http = require "luci.http"
    local util = require "luci.util"
    local json = require "luci.jsonc"
    
    local period = http.formvalue("period") or "day"
    local date = http.formvalue("date")
    
    if not date then
        if period == "month" then
            date = os.date("%Y-%m")
        else
            date = os.date("%Y-%m-%d")
        end
    end
    
    -- 调用 traffic.uc 获取数据
    local cmd = string.format("/usr/bin/ucode /etc/nikki/ucode/traffic.uc stats %s %s 2>&1",
        util.shellquote(period),
        util.shellquote(date))
    
    local raw_data = util.exec(cmd)
    
    -- 解析并返回 JSON
    http.prepare_content("application/json")
    
    -- 尝试解析返回的 JSON
    local parsed = json.parse(raw_data)
    if parsed then
        http.write_json(parsed)
    else
        -- 如果解析失败，返回原始数据或错误
        http.write('{"error": "Failed to parse traffic data", "raw": ' .. json.stringify(raw_data) .. '}')
    end
end
