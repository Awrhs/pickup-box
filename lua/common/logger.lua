local cjson = require "cjson.safe"
local ngx = ngx
local ngx_now = ngx.now
local worker_id = ngx.worker.id

local _M = {}

local function generate_trace_id()
    local time = ngx_now()
    local pid = worker_id() or 0
    local conn = ngx.var.connection or "0"
    local seed = time .. pid .. conn
    return ngx.md5(seed)
end

function _M.init_request()
    ngx.ctx.trace_id = generate_trace_id()
    ngx.ctx.start_time = ngx_now()
    ngx.ctx.user_id = nil
    ngx.ctx.content_id = nil
    ngx.ctx.device_mac = nil
    ngx.ctx.client_ip = nil
end

local function build_log_entry(event, data)
    local entry = {
        trace_id = ngx.ctx.trace_id,
        timestamp = ngx_now() * 1000,
        worker_id = worker_id(),
        event = event,
        user_id = ngx.ctx.user_id,
        content_id = ngx.ctx.content_id,
        device_mac = ngx.ctx.device_mac,
        client_ip = ngx.ctx.client_ip
    }

    if ngx.ctx.start_time then
        entry.elapsed_ms = (ngx_now() - ngx.ctx.start_time) * 1000
    end

    if data then
        for k, v in pairs(data) do
            entry[k] = v
        end
    end

    return entry
end

function _M.info(event, data)
    local entry = build_log_entry(event, data)
    ngx.log(ngx.INFO, cjson.encode(entry))
end

function _M.warn(event, data)
    local entry = build_log_entry(event, data)
    ngx.log(ngx.WARN, cjson.encode(entry))
end

function _M.err(event, data)
    local entry = build_log_entry(event, data)
    ngx.log(ngx.ERR, cjson.encode(entry))
end

function _M.debug(event, data)
    local entry = build_log_entry(event, data)
    ngx.log(ngx.DEBUG, cjson.encode(entry))
end

function _M.set_context(key, value)
    ngx.ctx[key] = value
end

function _M.get_trace_id()
    return ngx.ctx.trace_id
end

return _M
