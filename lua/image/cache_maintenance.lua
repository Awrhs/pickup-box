-- Disk cache capacity protection: periodically enforce a byte quota on the
-- derivative cache directory, deleting least-recently-modified files first.
--
-- The heavy lifting (directory walk + stat + sort + unlink) is done in C by
-- iv_cache_enforce_quota so it does not block the Lua event loop on stat I/O
-- beyond what glib file ops already do (the timer runs out of request path).
--
-- Only worker 0 runs the timer, following the project convention.
local config = require "image.config"
local vips = require "image.vips_ffi"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

local CHECK_INTERVAL = 300  -- seconds between quota sweeps

-- Default derivative cache cap: 5 GiB. Tunable via IMAGE_CACHE_MAX_BYTES.
local function quota_bytes()
    return tonumber(os.getenv("IMAGE_CACHE_MAX_BYTES")) or (5 * 1024 * 1024 * 1024)
end

-- Run one sweep. Returns true on success.
function _M.sweep()
    if not vips.available() then
        return false
    end
    local target = quota_bytes()
    local before = vips.cache_dir_size(config.cache_dir)
    local after, deleted = vips.cache_enforce_quota(config.cache_dir, target)
    if not after then
        logger.err("cache_quota_sweep_failed", { error = deleted })
        return false
    end
    if deleted and deleted > 0 then
        logger.warn("cache_quota_evicted", {
            before_bytes = before, after_bytes = after, deleted = deleted,
        })
    end


    return true
end

-- Start the recurring timer. Call once from init_worker_by_lua on worker 0.
function _M.init()
    if ngx.worker.id() ~= 0 then
        return
    end

    local function run(premature)
        if premature then return end
        -- pcall so a sweep error never kills the recurring timer.
        pcall(_M.sweep)
        -- Also checkpoint the SQLite WAL so it doesn't grow unbounded and
        -- run a quick PRAGMA optimize (SQLite 3.18+) to update stats.
        pcall(function()
            local m = require "image.metadata"
            if m.ready() then
                m.checkpoint()
            end
        end)
        local ok, err = ngx.timer.at(CHECK_INTERVAL, run)
        if not ok then
            ngx.log(ngx.ERR, "[CACHE_MAINT] failed to schedule timer: ", err)
        end
    end

    local ok, err = ngx.timer.at(CHECK_INTERVAL, run)
    if not ok then
        ngx.log(ngx.ERR, "[CACHE_MAINT] failed to initial timer: ", err)
    end
end

return _M
