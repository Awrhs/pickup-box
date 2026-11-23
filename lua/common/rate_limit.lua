-- Sliding-window (10s buckets) upload throttle, keyed per upload key.
-- State lives in the `upload_limit` shared dict so all workers agree.
local ngx = ngx
local logger = require "common.logger"

local _M = {}

local config = {
    upload_max_requests = tonumber(os.getenv("UPLOAD_MAX_REQUESTS")) or 600,
    upload_window_seconds = tonumber(os.getenv("UPLOAD_WINDOW")) or 60,
    enabled = true,
}

local BUCKET_SIZE = 10

local function current_bucket()
    return math.floor(ngx.time() / BUCKET_SIZE)
end

-- Sums the buckets inside the window, then increments the current bucket.
-- Expired buckets age out through the dict TTL, so no key scan is needed.
local function increment_sliding_window(dict, prefix, key, max_requests, window_seconds)
    local cur = current_bucket()
    local window_buckets = math.ceil(window_seconds / BUCKET_SIZE)

    local total = 0
    for i = cur - window_buckets + 1, cur do
        total = total + (tonumber(dict:get(prefix .. ":" .. key .. ":" .. i)) or 0)
    end

    if total >= max_requests then
        return false, total
    end

    local newval, err = dict:incr(prefix .. ":" .. key .. ":" .. cur, 1, 0, window_seconds + BUCKET_SIZE)
    if not newval then
        ngx.log(ngx.ERR, "[RATE-LIMIT] Failed to increment: ", err)
        return true, 0  -- fail-open
    end
    return true, newval
end

-- Keys are hashed so a secret is never stored verbatim in the shared dict.
function _M.check_upload_limit(api_key)
    if not config.enabled or not api_key or api_key == "" then
        return true
    end
    local dict = ngx.shared.upload_limit
    if not dict then
        ngx.log(ngx.ERR, "[RATE-LIMIT] Shared dict 'upload_limit' not found")
        return true
    end
    local digest = ngx.md5(api_key)
    local allowed, count = increment_sliding_window(
        dict, "upload", digest, config.upload_max_requests, config.upload_window_seconds)
    if not allowed then
        ngx.log(ngx.WARN, "[RATE-LIMIT] Upload limit exceeded: key(hash)=", digest, " count=", count)
        return false
    end
    return true
end

function _M.block_request(reason)
    logger.warn("rate_limit_exceeded", { reason = reason })
    ngx.status = 429
    ngx.header["Retry-After"] = tostring(BUCKET_SIZE)
    ngx.header.content_type = "text/plain"
    ngx.say("429 Too Many Requests - ", reason)
    ngx.exit(429)
end

function _M.set_config(new_config)
    for _, k in ipairs({ "upload_max_requests", "upload_window_seconds" }) do
        if new_config[k] then config[k] = tonumber(new_config[k]) end
    end
    if new_config.enabled ~= nil then config.enabled = new_config.enabled end
end

return _M
