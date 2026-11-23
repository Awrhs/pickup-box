-- API key authentication for upload/delete/admin endpoints.
--
-- Secrets are NEVER stored in plaintext: at load time each configured key is
-- reduced to sha256(secret) and only that hash is kept in memory and written
-- to the database as `uploaded_by`. At request time the presented secret is
-- hashed and looked up by hash in constant time over the configured set.
--
-- Two roles are supported:
--   * "upload" — can upload and delete/modify its own images
--   * "admin"  — can also list and delete anyone's images and view stats
--
-- Provisioning is via IMAGE_API_KEYS (comma-separated) and/or
-- IMAGE_API_KEY_FILE (newline-separated), each entry formatted as
--     name:secret[:role[:quota[:expires]]]
--
-- `expires` is an absolute Unix timestamp; past it the key is rejected even
-- if still present in the file, which gives operators safe key rotation
-- without a reload (simply set a new key with the old one's expires in the
-- past).
local config = require "image.config"
local security = require "image.security"
local bit = require "bit"
local sha = require "resty.sha256"
local to_hex = require "resty.string".to_hex
local ngx = ngx

local _M = {}

-- Reject presented keys shorter than this to prevent users from
-- accidentally configuring trivial secrets. Configurable via
-- IMAGE_MIN_KEY_LENGTH (default 16).
local MIN_KEY_LENGTH = tonumber(os.getenv("IMAGE_MIN_KEY_LENGTH")) or 16

-- Constant-time hex comparison.
local function const_eq_hex(a, b)
    if not a or not b or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(string.byte(a, i), string.byte(b, i)))
    end
    return diff == 0
end

local function hash_secret(secret)
    local h = sha:new()
    h:update(secret)
    return to_hex(h:final())
end

-- Look up a presented secret against all configured keys and return the
-- subject table { name, hash, role, quota, expires } or nil.
--
-- This is intentionally a constant-time scan over every configured key: we do
-- NOT index by hash (a table lookup would short-circuit and turn response
-- time into a membership oracle). The number of keys in a personal/small-team
-- image host is small (dozens at most), so a linear scan per authenticated
-- request is cheap.
local function resolve(presented)
    if not presented or presented == "" then return nil end
    if #presented < MIN_KEY_LENGTH then return nil, "short" end
    config.reload_key_file()

    local h = hash_secret(presented)
    local match
    for name, entry in pairs(config.api_keys) do
        if const_eq_hex(entry.hash, h) then
            if entry.expires and entry.expires ~= 0
               and ngx.time() > entry.expires then
                return nil, "expired"
            end
            match = {
                name = name,
                hash = h,
                role = entry.role or "upload",
                quota = entry.quota,
                expires = entry.expires,
            }
        end
    end
    if match then return match end
    return nil, "invalid"
end

-- Extract the raw presented key from the request. The query-string fallback
-- is gated by IMAGE_ALLOW_QUERY_KEY so production deployments can force
-- Authorization headers only (prevents keys leaking into access logs,
-- Referer headers, and browser history).
function _M.extract_key()
    local auth = ngx.var.http_authorization
    if auth then
        local key = auth:match("^%s*[Bb]earer%s+(%S+)%s*$")
        if key then return key, "header" end
    end
    if security.config.allow_query_key then
        local args = ngx.req.get_uri_args()
        local k = args.api_key or args.key
        if k then return k, "query" end
    end
    return nil, nil
end

function _M.authenticate()
    local raw, source = _M.extract_key()
    local subj, reason = resolve(raw)
    if not subj then return nil, nil, reason end
    if source == "query" then
        security.audit("api_key_in_query",
            { key_name = subj.name, path = ngx.var.uri })
    end
    return subj, raw
end

function _M.require()
    local raw, source = _M.extract_key()
    local subj, reason = resolve(raw)
    if not subj then
        security.audit("auth_failed", { reason = reason, source = source })
        if reason == "expired" then
            ngx.header["WWW-Authenticate"] =
                'Bearer realm="image", error="invalid_token", error_description="key expired"'
        else
            ngx.header["WWW-Authenticate"] = 'Bearer realm="image"'
        end
        ngx.status = 401
        ngx.header.content_type = "text/plain"
        ngx.say("401 Unauthorized - valid API key required")
        ngx.exit(401)
    end
    if source == "query" then
        security.audit("api_key_in_query",
            { key_name = subj.name, path = ngx.var.uri })
    end
    return subj
end

function _M.require_admin()
    local subj = _M.require()
    if subj.role ~= "admin" then
        ngx.status = 403
        ngx.header.content_type = "text/plain"
        ngx.say("403 Forbidden - admin role required")
        security.audit("forbidden",
            { key_name = subj.name, path = ngx.var.uri })
        ngx.exit(403)
    end
    return subj
end

return _M
