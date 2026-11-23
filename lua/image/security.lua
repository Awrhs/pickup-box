-- Cross-cutting security helpers for the image hosting subsystem:
--   * startup secret validation (warn/fail)
--   * CORS header emission
--   * audit logging (separate JSON log file)
--   * Content-Security-Policy nonce generation for HTML pages
--   * early request body size rejection
--   * original-image sanitization decision (serve inline with sandbox, or
--     force attachment, or re-encode)
local ngx = ngx
local os = os
local ffi = require "ffi"
local bit = require "bit"
local to_hex = require "resty.string".to_hex

local _M = {}

local function bool(v, d)
    if v == nil then return d end
    return v == "1" or v == "true" or v == "TRUE" or v == "yes"
end

_M.config = {
    -- If true, fail startup when download signing is enabled but no strong
    -- secret is configured. If false, just warn.
    require_strong_secret = bool(os.getenv("IMAGE_REQUIRE_STRONG_SECRET"), false),
    -- Allow ?api_key= on query string (default true for backwards compat;
    -- set to false to force Authorization header only).
    allow_query_key      = bool(os.getenv("IMAGE_ALLOW_QUERY_KEY"), true),
    -- CORS origin for /upload and /i/*: "*" or a specific origin. Empty
    -- (default) means no CORS headers (same-origin only).
    cors_origin          = os.getenv("IMAGE_CORS_ORIGIN") or "",
    -- How original (untransformed) images should be served:
    --   "inline"  - Content-Disposition: inline (default, sandbox CSP applies)
    --   "attachment" - force download (defends against polyglot sniffing)
    --   "sanitize" - re-encode the original through libvips on first access
    original_disposition = os.getenv("IMAGE_ORIGINAL_DISPOSITION") or "inline",
    -- Minimum length (bytes) for API key secrets.
    min_key_length       = tonumber(os.getenv("IMAGE_MIN_KEY_LENGTH")) or 16,
}

-- Validate signing-related config. Returns (ok, messages). On startup the
-- caller should log messages at WARN unless require_strong_secret is set,
-- in which case a missing/weak secret is fatal.
function _M.validate_secrets()
    local msgs = {}
    local sign_env = os.getenv("IMAGE_DOWNLOAD_SIGNED_URLS") == "true"
    local secret = os.getenv("IMAGE_DOWNLOAD_SECRET") or ""
    if sign_env and (not secret or #secret < 32) then
        msgs[#msgs + 1] = "IMAGE_DOWNLOAD_SIGNED_URLS=true but IMAGE_DOWNLOAD_SECRET is missing or <32 chars"
    end
    if secret and secret:find("change%-me", 1, false) then
        msgs[#msgs + 1] = "signing secret is a default placeholder"
    end
    local ok = #msgs == 0
    if not ok and _M.config.require_strong_secret then
        return false, msgs
    end
    return true, msgs
end

-- Emit CORS headers if configured. Safe to call on every response.
function _M.cors_headers()
    local origin = _M.config.cors_origin
    if origin == "" then return end
    ngx.header["Access-Control-Allow-Origin"] = origin
    ngx.header["Vary"] = (ngx.header["Vary"] and (ngx.header["Vary"] .. ", ") or "")
                       .. "Origin"
    if origin ~= "*" then
        ngx.header["Access-Control-Allow-Credentials"] = "true"
    end
    ngx.header["Access-Control-Allow-Methods"] = "GET, HEAD, OPTIONS, POST, DELETE"
    ngx.header["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
    ngx.header["Access-Control-Max-Age"] = "600"
end

-- Handle CORS preflight (OPTIONS). Call this from access_by_lua for
-- CORS-enabled locations.
function _M.preflight()
    if ngx.req.get_method() == "OPTIONS" and _M.config.cors_origin ~= "" then
        _M.cors_headers()
        ngx.status = 204
        ngx.exit(204)
        return true
    end
    return false
end

-- Generate a per-request CSP nonce. Cached on ngx.ctx so all calls in the
-- same request return the same value.
function _M.csp_nonce()
    if ngx.ctx.image_csp_nonce then return ngx.ctx.image_csp_nonce end
    -- 16 random bytes from /dev/urandom via FFI. If unavailable, fall back
    -- to time + worker pid + counter (less ideal but functional).
    local nonce
    local ok, urnd = pcall(function()
        local ffi = require "ffi"
        ffi.cdef[[
        typedef struct { unsigned long a,b; } iv_nonce_t;
        int getrandom(void *buf, unsigned long buflen, unsigned int flags);
        ]]
        local buf = ffi.new("char[18]")
        if ffi.C.getrandom(buf, 18, 1) == 18 then
            local b = require("resty.string").to_hex(
                ffi.string(buf, 16))
            return b
        end
        return nil
    end)
    if ok and urnd then nonce = urnd end
    if not nonce then
        local resty_sha = require "resty.sha256"
        local s = resty_sha:new()
        s:update(tostring(ngx.time()) .. tostring(ngx.worker.pid())
            .. tostring(ngx.var.connection) .. tostring(ngx.now()))
        nonce = to_hex(s:final()):sub(1, 24)
    end
    ngx.ctx.image_csp_nonce = nonce
    return nonce
end

-- Return a strict CSP string that allows inline styles/scripts only via nonce.
function _M.html_csp()
    local n = _M.csp_nonce()
    return "default-src 'none'; "
        .. "script-src 'nonce-" .. n .. "' 'strict-dynamic'; "
        .. "style-src 'nonce-" .. n .. "' 'self'; "
        .. "img-src 'self' data:; "
        .. "form-action 'self'; "
        .. "base-uri 'none'; frame-ancestors 'none'"
end

-- Return a CSP suitable for image responses: no JS, no embedding in frames
-- (defends against drag-and-drop UI redress).
function _M.image_csp()
    return "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; "
        .. "sandbox; frame-ancestors 'none'"
end

-- Audit logger. Writes JSON lines to logs/audit.log (separate from the main
-- access log so it can be shipped/alerted independently).
local audit_fp
local function audit_file()
    if audit_fp then return audit_fp end
    local ffi = require "ffi"
    ffi.cdef[[
    typedef struct iv_file FILE;
    FILE *fopen(const char *path, const char *mode);
    int fflush(FILE *stream);
    int fclose(FILE *stream);
    size_t fwrite(const void *ptr, size_t size, size_t n, FILE *s);
    ]]
    local path = os.getenv("IMAGE_AUDIT_LOG") or "/var/log/nginx/audit.log"
    audit_fp = ffi.C.fopen(path, "a")
    return audit_fp
end

local cjson
function _M.audit(event, data)
    data = data or {}
    data.event = event
    data.ts = ngx.time()
    data.trace_id = ngx.ctx and ngx.ctx.trace_id
    data.ip = client_ip_safe()
    cjson = cjson or require "cjson.safe"
    local line = cjson.encode(data) or "{}"
    local fp = audit_file()
    if fp ~= nil then
        local ffi = require "ffi"
        ffi.C.fwrite(line, 1, #line, fp)
        ffi.C.fwrite("\n", 1, 1, fp)
        ffi.C.fflush(fp)
    end
    -- Also mirror through the structured logger.
    local logger = require "common.logger"
    logger.warn("audit_" .. event, data)
end

function client_ip_safe()
    local ok, m = pcall(require, "image.client_ip")
    if ok then return m.get() end
    return ngx.var.remote_addr or "unknown"
end

-- Early reject based on Content-Length. Returns true if the request was
-- terminated (caller should stop processing).
function _M.enforce_max_upload(max_bytes)
    local cl = ngx.var.http_content_length
    if cl and tonumber(cl) and tonumber(cl) > max_bytes then
        ngx.status = 413
        ngx.header.content_type = "text/plain"
        ngx.say("413 Payload Too Large")
        ngx.exit(413)
        return true
    end
    return false
end

-- Decide whether the original should be served as an attachment. Applies
-- only to untransformed /i/<hash>.<ext> requests (caller decides when to
-- invoke — transform.lua serves bytes from processing, not originals).
function _M.original_content_disposition(hash, ext)
    local mode = _M.config.original_disposition
    if mode == "attachment" then
        return 'attachment; filename="' .. hash .. '.' .. ext .. '"'
    end
    return nil
end

return _M
