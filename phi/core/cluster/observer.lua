---
--- Generated by EmmyLua(https://github.com/EmmyLua)
--- Created by Young.Z
--- DateTime: 2018/5/3 13:54
---
local ev = require("resty.worker.events")
local red = require("tools.redis")

local ngx_time_at = ngx.timer.at
local logger = ngx.log
local CRIT = ngx.CRIT
local ngx_now = ngx.now
local ipairs = ipairs
local cjson = require("cjson.safe")
local worker_id = ngx.worker.id
local CACHE_KEY_PREFIX = "phi:cluster:event:id:"
local SERIAL_ID_KEY = "phi:cluster:event:serial_id"
local pretty_write = require("pl.pretty").write
local MATCH = CACHE_KEY_PREFIX .. "*"
local PHI_EVENTS = require("core.constants").DICTS.PHI_EVENTS
local dict = ngx.shared[PHI_EVENTS]
--- 节点ID、抓取数据周期、最大抓取数量、事件有效期、启动时间
local node_id = "localhost"
local delay = 1
local max = 10
local timeout = 1000
local start_up_time = ngx_now()
local processing = false

local serial_cache_key = CACHE_KEY_PREFIX .. "current_event_serial"
local get_current_event_serial = function()
    return dict:get(serial_cache_key) or 0
end
local set_current_event_serial = function(value)
    return dict:set(serial_cache_key, value)
end

local log = function(...)
    logger(CRIT, ...)
end
local _ok, new_tab = pcall(require, "table.new")
if not _ok or type(new_tab) ~= "function" then
    new_tab = function()
        return {}
    end
end
local function fetchData()
    local res, err = red:scan(0, "MATCH", MATCH, "COUNT", max)
    if not err then
        local keys = res[2]
        red:init_pipeline(#keys)
        for _, k in ipairs(keys) do
            red:get(k)
        end
        res, err = red:commit_pipeline()
        if res then
            local result = new_tab(#keys, 0)
            for i, item_str in ipairs(res) do
                local item, e = cjson.decode(item_str)
                if type(item_str) ~= "number" then
                    if item then
                        result[i] = item
                    else
                        log("查询事件内容失败！err:", e)
                        -- key数据无效，删除之
                        red:delete(keys[i])
                    end
                end
            end
            return result
        end
    end
    return nil, err
end

--[[
events:{
    "source":"",
    "event":"",
    "data":"",
    "unique":"",
    "node_id":"",
    "timestamp":"",
    "id":""
}
]]
local function poll_event()
    if processing then
        local ok, err = ngx_time_at(delay, poll_event)
        if not ok then
            log("failed to start recurring polling timer: ", err)
        end
        return
    end
    processing = true
    local events, err = fetchData()
    if err then
        log("polling event failed！err:", err)
        local ok, err = ngx_time_at(delay, poll_event)
        if not ok then
            log("failed to start recurring polling timer: ", err)
        end
        processing = false
        return
    end

    for i, item in ipairs(events) do
        -- 未处理且创建时间晚于节点启动时间的事件
        if item.id > get_current_event_serial() and start_up_time < item.timestamp and node_id ~= events.node_id then
        log(pretty_write(item))
            set_current_event_serial(item.id)
            ev.post(item.source, "cluster", {
                event = item.event,
                data = item.data,
                unique = item.unique
            }, CACHE_KEY_PREFIX .. item.id)
        end
    end

    local ok, err = ngx_time_at(delay, poll_event)
    if not ok then
        log("failed to start recurring polling timer: ", err)
    end
    processing = false
end

local _M = {}
function _M.post(source, event, data, unique, localEvent)
    -- 集群事件处理
    if not localEvent then
        local clusterEvent = {
            source = source,
            event = event,
            data = data,
            unique = unique,
            node_id = node_id,
            timestamp = ngx_now()
        }

        local r, e = red:eval([[
            local serial = redis.call('incr',KEYS[1])
            local tab = cjson.decode(ARGV[2])
            tab.id = serial
            return redis.call('setex',KEYS[2] .. serial,tonumber(ARGV[1]),cjson.encode(tab))
        ]], 2, SERIAL_ID_KEY, CACHE_KEY_PREFIX, timeout, cjson.encode(clusterEvent))
        log("post cluster event; source=", source,
                ", event=", event,
                ", data=", pretty_write(data))
    end
    ev.post(source, event, data, unique)
end

function _M:new(redis, event)
    red = redis
    ev = event
    return setmetatable(self, { __index = ev })
end

function _M:init_worker()
    -- 只使用一个worker处理集群事件
    if worker_id() ~= 0 then
        return
    end
    log("start to poll cluster event")
    ngx_time_at(5, poll_event)
end

return _M