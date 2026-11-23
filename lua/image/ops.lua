-- Operational endpoints: /healthz (liveness), /readyz (readiness), /metrics.
local ngx = ngx
local cjson = require "cjson.safe"

local _M = {}

-- Build/version metadata written at image build time, if present.
local function version_info()
    local ok, fs = pcall(require, "image.fs_ffi")
    if not ok then return nil end
    for _, p in ipairs({ "/opt/pickup-box/VERSION", "/etc/pickup-box/version" }) do
        local v = fs.read_file(p)
        if v and #v > 0 then
            return (v:gsub("%s+$", ""))
        end
    end
    return nil
end

function _M.health_check()
    ngx.status = 200
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({ status = "ok", timestamp = ngx.time(), version = version_info() }))
    ngx.exit(200)
end

-- Ready when libvips, SQLite, storage directories and disk space check out.
function _M.ready_check()
    local ok, checks = require("image.ready").ready()
    local status = ok and 200 or 503
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        status = ok and "ready" or "not_ready",
        timestamp = ngx.time(),
        checks = checks,
    }))
    ngx.exit(status)
end

function _M.metrics()
    require("common.metrics").emit_metrics()
end

return _M
