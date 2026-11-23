-- Prometheus metrics. Counters live in the `metrics_stats` shared dict so
-- they are consistent across workers; histograms are per-worker (a known
-- limitation: each scrape sees the worker that served it).
local ngx = ngx
local shared = ngx.shared
local ipairs = ipairs
local tonumber = tonumber

local _M = {}

local PREFIX = "pickupbox_"
local metrics_dict = shared.metrics_stats

local HISTOGRAM_BUCKETS = { 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

local histograms = {
    image_process_duration = {},
}

for name in pairs(histograms) do
    local h = {}
    for _, b in ipairs(HISTOGRAM_BUCKETS) do h[b] = 0 end
    h.sum, h.count = 0, 0
    histograms[name] = h
end

local function dict_incr(key, value)
    if metrics_dict then
        metrics_dict:incr(key, value or 1, 0)
    end
end

local function dict_get(key)
    if not metrics_dict then return 0 end
    return tonumber(metrics_dict:get(key)) or 0
end

function _M.incr_image_upload()      dict_incr("image_uploads") end
function _M.incr_image_cache_hit()   dict_incr("image_cache_hits") end
function _M.incr_image_cache_miss()  dict_incr("image_cache_misses") end
function _M.incr_image_processed()   dict_incr("image_processed") end
function _M.incr_image_error()       dict_incr("image_errors") end

-- Product counters.
function _M.incr(name) dict_incr("pb:" .. name) end
local PRODUCT_COUNTERS = {
    { "shares_created", "Shares created" },
    { "share_visits", "Pickup page opens that counted as a visit" },
    { "pickup_code_failures", "Wrong or blocked pickup code attempts" },
    { "auth_failures", "Failed password attempts" },
    { "zip_downloads", "Zip archives streamed" },
    { "file_downloads", "Single files served" },
}

local function observe_histogram(name, seconds)
    local h = histograms[name]
    if not h then return end
    h.sum = h.sum + seconds
    h.count = h.count + 1
    for _, b in ipairs(HISTOGRAM_BUCKETS) do
        if seconds <= b then h[b] = h[b] + 1 end
    end
end

function _M.observe_image_process(seconds)
    observe_histogram("image_process_duration", seconds)
end

local function say_metric(name, kind, help, value, labels)
    ngx.say("# HELP ", PREFIX, name, " ", help)
    ngx.say("# TYPE ", PREFIX, name, " ", kind)
    if value ~= nil then
        ngx.say(PREFIX, name, labels or "", " ", value)
    end
end

local function emit_histogram(name, help, h)
    say_metric(name, "histogram", help)
    -- Buckets are already cumulative (each observation increments every
    -- bucket whose bound it fits under).
    for _, b in ipairs(HISTOGRAM_BUCKETS) do
        ngx.say(PREFIX, name, "_bucket{le=\"", b, "\"} ", h[b])
    end
    ngx.say(PREFIX, name, "_bucket{le=\"+Inf\"} ", h.count)
    ngx.say(PREFIX, name, "_sum ", h.sum)
    ngx.say(PREFIX, name, "_count ", h.count)
end

local function emit_shared_dict(name)
    local d = ngx.shared[name]
    if not d then return end
    ngx.say(PREFIX, "shared_dict_capacity_bytes{name=\"", name, "\"} ", d:capacity())
    -- ngx.shared.DICT has capacity()/free_space(); there is no used().
    ngx.say(PREFIX, "shared_dict_used_bytes{name=\"", name, "\"} ", d:capacity() - d:free_space())
end

local SHARED_DICTS = {
    "metrics_stats", "circuit_state", "upload_limit", "pickup_locks", "pickup_guard",
    "image_locks", "image_l1", "image_downloads",
}

function _M.emit_metrics()
    ngx.status = 200
    ngx.header.content_type = "text/plain; version=0.0.4"

    say_metric("info", "gauge", "Static build information", 1)

    say_metric("shared_dict_capacity_bytes", "gauge", "Shared dictionary capacity")
    say_metric("shared_dict_used_bytes", "gauge", "Shared dictionary used bytes")
    for _, n in ipairs(SHARED_DICTS) do emit_shared_dict(n) end

    for _, c in ipairs(PRODUCT_COUNTERS) do
        say_metric(c[1] .. "_total", "counter", c[2], dict_get("pb:" .. c[1]))
    end

    say_metric("image_uploads_total", "counter", "Total uploads", dict_get("image_uploads"))
    say_metric("image_cache_hits_total", "counter", "Derivative cache hits", dict_get("image_cache_hits"))
    say_metric("image_cache_misses_total", "counter", "Derivative cache misses", dict_get("image_cache_misses"))
    say_metric("image_processed_total", "counter", "Images transformed via libvips", dict_get("image_processed"))
    say_metric("image_errors_total", "counter", "Image processing errors", dict_get("image_errors"))

    -- Download-side metrics, populated by image.download_guard (hourly buckets).
    local dl = ngx.shared.image_downloads
    if dl then
        local now_bucket = math.floor(ngx.time() / 3600)
        local bw_total, req_total = 0, 0
        for _, b in ipairs({ now_bucket, now_bucket - 1 }) do
            bw_total  = bw_total  + (tonumber(dl:get("bw:total:" .. b)) or 0)
            req_total = req_total + (tonumber(dl:get("req:total:" .. b)) or 0)
        end
        say_metric("download_bytes_total", "counter", "Bytes served (current + previous hour)", bw_total)
        say_metric("download_requests_total", "counter", "Download requests (current + previous hour)", req_total)
        say_metric("download_ratelimited_total", "counter", "Requests blocked by the download rate limiter",
                   tonumber(dl:get("rl_blocked")) or 0)
        say_metric("download_referer_blocked_total", "counter", "Requests blocked by referer policy",
                   tonumber(dl:get("referer_blocked")) or 0)
        say_metric("download_signature_blocked_total", "counter", "Requests blocked by missing/invalid signature",
                   tonumber(dl:get("signature_blocked")) or 0)
    end

    -- Per-owner usage. Key hashes are truncated to 12 hex chars.
    local ok, rows = pcall(function()
        return require("image.metadata").usage_leaderboard(50)
    end)
    if ok and rows then
        say_metric("owner_bytes_used", "gauge", "Rolling-window bytes used per upload key (truncated hash)")
        say_metric("owner_uploads", "gauge", "Rolling-window uploads per upload key (truncated hash)")
        for _, r in ipairs(rows) do
            local label = (r.key_hash or "unknown"):sub(1, 12)
            ngx.say(PREFIX, 'owner_bytes_used{key="', label, '"} ', tonumber(r.bytes_used) or 0)
            ngx.say(PREFIX, 'owner_uploads{key="', label, '"} ', tonumber(r.uploads) or 0)
        end
    end

    emit_histogram("image_process_duration_seconds",
                   "Image processing (C/libvips) duration in seconds",
                   histograms.image_process_duration)

    ngx.exit(200)
end

return _M
