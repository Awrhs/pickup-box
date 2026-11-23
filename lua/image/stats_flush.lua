-- Periodic flush of per-image download counters from the image_downloads
-- shared dict into the stats_daily SQLite table.
--
-- The dict counters (imgc:<hash>:<day_bucket> and imgb:<hash>:<day_bucket>)
-- are atomically drained using incr(-flushed) so that concurrent meter() calls
-- between dict read and dict decrement cannot lose counts: the increment
-- clamps the key, so even if we subtract too much the counter bottoms at 0
-- and recovers on the next request.
--
-- Only worker 0 runs the timer, following project convention.
local config = require "image.config"
local metadata = require "image.metadata"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

local CHECK_INTERVAL = tonumber(os.getenv("IMAGE_STATS_FLUSH_INTERVAL")) or 60

-- Scan the dict for imgc:/imgb: keys and aggregate by (day, hash).
local function collect(acc)
    local dict = ngx.shared.image_downloads
    if not dict then return end
    local keys = dict:get_keys(0, "img")
    for _, key in ipairs(keys) do
        local ty, rest = key:match("^img(%w):(.+)$")
        if ty then
            local hash, day = rest:match("^([^:]+):(%d+)$")
            if hash and day then
                local val = tonumber(dict:get(key)) or 0
                if val > 0 then
                    local k = day .. ":" .. hash
                    local e = acc[k]
                    if not e then e = { count = 0, bytes = 0 }; acc[k] = e end
                    if ty == "c" then e.count = e.count + val end
                    if ty == "b" then e.bytes = e.bytes + val end
                    -- Atomically drain what we read so concurrent meter()
                    -- increments between get and incr cannot lose counts.
                    dict:incr(key, -val, 0, 86400 * 2)
                end
            end
        end
    end
end

-- Scan the dict, aggregate, and upsert each (day, hash) row.
function _M.flush()
    local dict = ngx.shared.image_downloads
    if not dict then return end

    local acc = {}
    collect(acc)

    for k, val in pairs(acc) do
        local day, hash = k:match("^(%d+):(.+)$")
        if day and hash and (val.count > 0 or val.bytes > 0) then
            metadata.bump_stats_daily(tonumber(day), hash,
                                      val.count, val.bytes)
        end
    end
end

function _M.init()
    if ngx.worker.id() ~= 0 then return end

    local function run(premature)
        if premature then return end
        pcall(_M.flush)
        local ok, err = ngx.timer.at(CHECK_INTERVAL, run)
        if not ok then
            ngx.log(ngx.ERR, "[STATS_FLUSH] failed to schedule timer: ", err)
        end
    end

    local ok, err = ngx.timer.at(CHECK_INTERVAL, run)
    if not ok then
        ngx.log(ngx.ERR, "[STATS_FLUSH] failed to initial timer: ", err)
    end
end

return _M