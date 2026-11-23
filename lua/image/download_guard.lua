-- Download-side protection for the public image endpoint:
--
--   1. Per-IP request rate limit (sliding window).
--   2. Optional Referer allow/block lists (hotlink protection).
--   3. Optional HMAC-signed URLs (`?e=<expiry>&s=<sig>`) so external sites
--      cannot fabricate working URLs.
--   4. Monthly bandwidth/request metering per source (anonymized IP hash).
--
-- All features are env-gated and default to permissive; enabling them is a
-- matter of setting the corresponding IMAGE_DOWNLOAD_* variables.
local bit = require "bit"
local resty_sha256 = require "resty.sha256"
local to_hex = require "resty.string".to_hex
local client_ip = require "image.client_ip"
local ngx = ngx
local os = os

local _M = {}

local function bool(v, d)
    if v == nil then return d end
    return v == "1" or v == "true" or v == "TRUE" or v == "yes"
end

local function num(v, d)
    local n = tonumber(v)
    if not n then return d end
    return n
end

local CFG = {
    -- Per-IP rate limit (requests per window).
    rl_requests   = num(os.getenv("IMAGE_DOWNLOAD_RPM"), 600),   -- req/min/IP
    rl_window     = num(os.getenv("IMAGE_DOWNLOAD_RATE_WINDOW"), 60),
    -- Referer policy.
    referer_mode  = os.getenv("IMAGE_DOWNLOAD_REFERER_MODE") or "off", -- off|allow|deny
    referer_list  = {},
    -- Signed URL requirement.
    signed_urls   = bool(os.getenv("IMAGE_DOWNLOAD_SIGNED_URLS"), false),
    secret        = os.getenv("IMAGE_DOWNLOAD_SECRET") or "",
    sign_ttl      = num(os.getenv("IMAGE_DOWNLOAD_SIGN_TTL"), 3600),
    -- Bandwidth metering (anonymous).
    meter_enabled = bool(os.getenv("IMAGE_DOWNLOAD_METER"), true),
}

-- Parse comma-separated host list. Hosts are matched case-insensitively as
-- suffixes so "example.com" also matches "cdn.example.com".
do
    local raw = os.getenv("IMAGE_DOWNLOAD_REFERER_LIST") or ""
    for host in string.gmatch(raw, "[^,]+") do
        host = host:lower():gsub("^%s+", ""):gsub("%s+$", "")
                 :gsub("^https?://", ""):gsub("^/", ""):gsub(":%d+$", "")
        if #host > 0 then CFG.referer_list[host] = true end
    end
end

-- In-memory sliding-window counters. Buckets are 10s, window is 60s.
local dict = ngx.shared.image_downloads
local BUCKET = 10
local function rate_limited(client_id)
    if not dict or CFG.rl_requests <= 0 then return false end
    local now = ngx.time()
    local bucket = math.floor(now / BUCKET)
    local total = 0
    local n_buckets = math.ceil(CFG.rl_window / BUCKET)
    for i = 0, n_buckets - 1 do
        total = total + (tonumber(dict:get(client_id .. ":" .. (bucket - i))) or 0)
    end
    if total >= CFG.rl_requests then
        dict:incr("rl_blocked", 1, 0, 86400)
        return true
    end
    dict:incr(client_id .. ":" .. bucket, 1, 0, CFG.rl_window + BUCKET)
    return false
end

local function client_id()
    -- Use the shared client_ip helper so X-Forwarded-For is handled correctly
    -- (and only when TRUST_X_FORWARDED_FOR is enabled). The salt ties the hash
    -- to our secret so it cannot be correlated across unrelated services.
    local id = client_ip.hashed(CFG.secret)
    return id
end

-- Check the Referer against the configured allow/deny list. An empty Referer
-- (direct hit, address bar, or `<img referrerpolicy="no-referrer">`) is
-- allowed when mode is "deny" (blocklist) and rejected when mode is "allow"
-- (allowlist), unless IMAGE_DOWNLOAD_REFERER_ALLOW_EMPTY is set.
local function referer_ok(referer)
    if CFG.referer_mode == "off" then return true end
    local allow_empty = bool(os.getenv("IMAGE_DOWNLOAD_REFERER_ALLOW_EMPTY"), false)

    if not referer or referer == "" then
        return allow_empty
    end
    local host = referer:lower():match("^https?://([^/:]+)")
    if not host then return false end

    if CFG.referer_mode == "allow" then
        if CFG.referer_list[host] then return true end
        -- suffix match: any configured parent domain counts.
        for allowed in pairs(CFG.referer_list) do
            if host:sub(-#allowed - 1) == "." .. allowed then return true end
        end
        return false
    elseif CFG.referer_mode == "deny" then
        if CFG.referer_list[host] then return false end
        for denied in pairs(CFG.referer_list) do
            if host:sub(-#denied - 1) == "." .. denied then return false end
        end
        return true
    end
    return true
end

-- HMAC-SHA256 in hex. Uses the same hand-rolled construction as
-- the resty.sha256 primitive (no resty.hmac dependency).
local function hmac_hex(key, data)
    local block = 64
    if #key > block then
        local s = resty_sha256:new(); s:update(key); key = s:final()
    end
    key = key .. string.rep("\0", block - #key)
    local ipad, opad = {}, {}
    for i = 1, block do
        local b = string.byte(key, i)
        ipad[i] = string.char(bit.bxor(b, 0x36))
        opad[i] = string.char(bit.bxor(b, 0x5c))
    end
    local si = resty_sha256:new(); si:update(table.concat(ipad)); si:update(data)
    local so = resty_sha256:new(); so:update(table.concat(opad)); so:update(si:final())
    return to_hex(so:final())
end

-- Build the canonical string that gets signed: "<path>|<expiry>|<query>" where
-- <query> is the URL transform parameters (w, h, q, fmt, fit, wm, gray, blur,
-- download) sorted by key and joined as "k=v&...". The `e` and `s` parameters
-- themselves are excluded so the signature can be verified by recomputing over
-- the same canonical form. This means a signed URL cannot be replayed with
-- different transform parameters (e.g. turn a thumbnail into a 4K version).
local SIGNABLE_KEYS = {
    w = true, h = true, q = true, fmt = true, fit = true, wm = true,
    watermark = true, gray = true, grayscale = true, greyscale = true,
    blur = true, download = true, dl = true,
}

-- Return (canonical_string_for_signing, query_string_for_url). The signing
-- string uses raw (already-decoded) values so it is deterministic regardless
-- of how the client percent-encodes the URL; the URL string is escaped for
-- embedding in a signed link.
local function canonical_query(args)
    local keys = {}
    for k in pairs(args or {}) do
        if SIGNABLE_KEYS[k] and k ~= "e" and k ~= "s" then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local sign_t, url_t = {}, {}
    for i, k in ipairs(keys) do
        local v = args[k]
        if type(v) == "table" then v = v[1] end
        v = tostring(v or "")
        sign_t[i] = k .. "=" .. v
        url_t[i]  = ngx.escape_uri(k) .. "=" .. ngx.escape_uri(v)
    end
    return table.concat(sign_t, "&"), table.concat(url_t, "&")
end

-- Signing convention (important for cross-language clients):
--
--   signed_string = "<path>|<expiry>|<sorted-k=v&...>"
--
-- where each parameter value is taken from `ngx.req.get_uri_args` (already
-- percent-decoded by nginx) and then joined verbatim. This means clients
-- generating signatures must compute the HMAC over the *decoded* values;
-- the URL may still carry them percent-encoded. The `/sign` endpoint does
-- this for you; use that rather than reimplementing in another language.
local function build_signed(path, expiry, args)
    local sign_q, url_q = canonical_query(args)
    local payload = table.concat({ path, tostring(expiry), sign_q }, "|")
    local sig = hmac_hex(CFG.secret, payload):sub(1, 32)
    return sig, url_q
end

local function signature_ok(path, expiry, sig, args)
    if not CFG.secret or CFG.secret == "" then return false end
    if not expiry or not sig then return false end
    if tonumber(expiry) < ngx.time() then return false end
    local expected = (build_signed(path, expiry, args))
    if #sig ~= #expected then return false end
    local diff = 0
    for i = 1, #sig do
        diff = bit.bor(diff, bit.bxor(string.byte(sig, i), string.byte(expected, i)))
    end
    return diff == 0
end

-- Sign a path plus optional transform args. Returns "e=...&s=...&<canonical>",
-- ready to append to the URL. The signed parameters are emitted in sorted,
-- percent-encoded form so the URL is self-contained and order-independent.
function _M.sign_path(path, ttl, args)
    if not CFG.secret or CFG.secret == "" then
        return nil, "no secret configured"
    end
    local exp = ngx.time() + (ttl or CFG.sign_ttl)
    local sig, url_q = build_signed(path, exp, args)
    return "e=" .. exp .. "&s=" .. sig .. (url_q ~= "" and ("&" .. url_q) or "")
end

-- Enforce all download-side checks. On failure, emits the appropriate status
-- and terminates the request.
function _M.enforce()
    local id = client_id()
    if rate_limited(id) then
        ngx.status = 429
        ngx.header["Retry-After"] = tostring(CFG.rl_window)
        ngx.header.content_type = "text/plain"
        ngx.say("429 Too Many Requests")
        ngx.exit(429)
    end

    local referer = ngx.var.http_referer
    if not referer_ok(referer) then
        if dict then dict:incr("referer_blocked", 1, 0, 86400) end
        ngx.status = 403
        ngx.header.content_type = "text/plain"
        ngx.say("403 Forbidden - referer not allowed")
        ngx.exit(403)
    end

    if CFG.signed_urls then
        local args = ngx.req.get_uri_args()
        if not signature_ok(ngx.var.uri, args.e, args.s, args) then
            if dict then dict:incr("signature_blocked", 1, 0, 86400) end
            ngx.status = 403
            ngx.header.content_type = "text/plain"
            ngx.say("403 Forbidden - invalid or missing signature")
            ngx.exit(403)
        end
    end
    return id
end

-- Record bandwidth usage for this response. Called from log_by_lua. We prefer
-- the exact byte count set by transform.lua in ngx.ctx.image_bytes (which
-- works even when the body is streamed via X-Accel-Redirect and the original
-- location's $body_bytes_sent may not be propagated); we fall back to the
-- caller-provided value (typically $body_bytes_sent).
function _M.meter(bytes_sent)
    if not CFG.meter_enabled or not dict then return end
    local bytes = (ngx.ctx and ngx.ctx.image_bytes) or bytes_sent or 0
    if bytes <= 0 then return end
    local id = client_id()
    local now = ngx.time()
    local bucket = math.floor(now / 3600)
    dict:incr("bw:" .. id .. ":" .. bucket, bytes, 0, 86400 * 2)
    dict:incr("bw:total:" .. bucket, bytes, 0, 86400 * 2)
    dict:incr("req:" .. id .. ":" .. bucket, 1, 0, 86400 * 2)
    dict:incr("req:total:" .. bucket, 1, 0, 86400 * 2)
end

-- Return approximate total bytes served in the last N hours (for /stats).
function _M.recent_bandwidth(hours)
    if not dict then return 0, 0 end
    hours = hours or 24
    local now_bucket = math.floor(ngx.time() / 3600)
    local bytes, reqs = 0, 0
    for i = 0, hours - 1 do
        bytes = bytes + (tonumber(dict:get("bw:total:" .. (now_bucket - i))) or 0)
        reqs  = reqs  + (tonumber(dict:get("req:total:" .. (now_bucket - i))) or 0)
    end
    return bytes, reqs
end

-- Override config at runtime (tests). Mirrors rate_limit.set_config.
function _M.set_config(overrides)
    for k, v in pairs(overrides) do CFG[k] = v end
end

-- Expose config for /admin/stats and tests.
function _M.config()
    return {
        rate_limit_requests = CFG.rl_requests,
        rate_limit_window   = CFG.rl_window,
        referer_mode        = CFG.referer_mode,
        signed_urls         = CFG.signed_urls,
        meter_enabled       = CFG.meter_enabled,
    }
end

return _M
