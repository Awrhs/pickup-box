-- pickup-box product configuration (env only, read at module load).
--
-- Everything a self-hoster is expected to touch is a PICKUP_* variable with a
-- safe default; sizes accept "2G"/"500M"/"1.5GB" and durations accept
-- "90s"/"10m"/"24h"/"7d"/"2w". Every variable listed here must also be
-- declared with `env NAME;` in conf/nginx.conf, or nginx hides it from Lua.
local _M = {}

local UNITS = { b = 1, k = 1024, m = 1024 ^ 2, g = 1024 ^ 3, t = 1024 ^ 4 }

-- "2G" -> 2147483648. Returns nil for malformed input.
function _M.parse_size(v)
    if v == nil then return nil end
    v = tostring(v):lower():gsub("%s+", "")
    if v == "" then return nil end
    local num, unit = v:match("^(%d+%.?%d*)([kmgt]?)i?b?$")
    if not num then return nil end
    local n = tonumber(num)
    if not n then return nil end
    return math.floor(n * (UNITS[unit ~= "" and unit or "b"]))
end

local DUR = { s = 1, m = 60, h = 3600, d = 86400, w = 7 * 86400 }

-- "7d" -> 604800; a bare number is seconds. Returns nil for malformed input.
function _M.parse_duration(v)
    if v == nil then return nil end
    v = tostring(v):lower():gsub("%s+", "")
    if v == "" then return nil end
    local num, unit = v:match("^(%d+%.?%d*)([smhdw]?)$")
    if not num then return nil end
    return math.floor(tonumber(num) * DUR[unit ~= "" and unit or "s"])
end

local function env(name) local v = os.getenv(name); if v == "" then return nil end; return v end
local function size_env(name, default) return _M.parse_size(env(name)) or default end
local function dur_env(name, default) return _M.parse_duration(env(name)) or default end
local function int_env(name, default, lo, hi)
    local n = tonumber(env(name))
    if not n then return default end
    n = math.floor(n)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

_M.site_name        = env("PICKUP_SITE_NAME") or "快传"
_M.domain           = env("PICKUP_DOMAIN")
-- Absolute base URL used in share links and QR codes. Derived from the
-- request (Host + X-Forwarded-Proto) when unset.
_M.public_url       = env("PICKUP_PUBLIC_URL")
if not _M.public_url and _M.domain and _M.domain:match("^[%w%.%-]+$") and _M.domain ~= "localhost" then
    _M.public_url = "https://" .. _M.domain
end
if _M.public_url then _M.public_url = _M.public_url:gsub("/+$", "") end

-- Upload limits.
_M.max_file_bytes   = size_env("PICKUP_MAX_FILE_SIZE", 2 * 1024 ^ 3)
_M.max_files        = int_env("PICKUP_MAX_FILES", 200, 1, 10000)
-- Rolling 30-day upload quota for non-admin passwords (0 = unlimited).
_M.quota_bytes      = size_env("PICKUP_QUOTA", 20 * 1024 ^ 3)
-- Refuse new uploads when free disk would drop below this share of the disk.
_M.min_free_percent = int_env("PICKUP_MIN_FREE_PERCENT", 10, 0, 90)

-- Share lifetime.
_M.default_expiry   = dur_env("PICKUP_DEFAULT_EXPIRY", 7 * 86400)
_M.max_expiry       = dur_env("PICKUP_MAX_EXPIRY", 30 * 86400)
_M.min_expiry       = dur_env("PICKUP_MIN_EXPIRY", 600)
if _M.min_expiry > _M.max_expiry then _M.min_expiry = _M.max_expiry end
if _M.default_expiry > _M.max_expiry then _M.default_expiry = _M.max_expiry end
if _M.default_expiry < _M.min_expiry then _M.default_expiry = _M.min_expiry end
_M.max_visits_limit = 1000

-- Pickup code: digits only (easy to type on a phone keypad).
_M.code_length      = int_env("PICKUP_CODE_LENGTH", 6, 4, 10)
_M.slug_length      = 10

-- Recipient access token lifetime: refreshing the pickup page within this
-- window does not consume another visit.
_M.token_ttl        = dur_env("PICKUP_TOKEN_TTL", 6 * 3600)

-- Housekeeping.
_M.keep_expired     = dur_env("PICKUP_KEEP_EXPIRED", 7 * 86400)   -- history rows
_M.upload_grace     = dur_env("PICKUP_UPLOAD_GRACE", 24 * 3600)   -- unshared blobs
_M.gc_interval      = dur_env("PICKUP_GC_INTERVAL", 600)

-- Brute-force limits.
_M.code_fail_limit  = int_env("PICKUP_CODE_FAIL_LIMIT", 10, 1)     -- per IP per hour
_M.code_fail_global = int_env("PICKUP_CODE_FAIL_GLOBAL", 300, 10)  -- all IPs per hour
_M.auth_fail_limit  = int_env("PICKUP_AUTH_FAIL_LIMIT", 10, 1)     -- per IP per 15 min

-- Passwords. PICKUP_PASSWORD is the owner (admin) password; PICKUP_USERS
-- adds more accounts as "name:password[:role]" separated by commas.
_M.owner_password   = env("PICKUP_PASSWORD")
_M.users            = env("PICKUP_USERS")
_M.min_password_len = int_env("PICKUP_MIN_PASSWORD_LENGTH", 12, 8, 128)

-- Optional bearer token that unlocks /metrics for remote scrapers. Without
-- it /metrics only answers requests from inside the container.
_M.metrics_token    = env("PICKUP_METRICS_TOKEN")

-- Expiry choices offered by the upload page (seconds), clamped to limits.
_M.expiry_choices = {}
for _, s in ipairs({ 3600, 86400, 3 * 86400, 7 * 86400, 30 * 86400 }) do
    if s >= _M.min_expiry and s <= _M.max_expiry then
        _M.expiry_choices[#_M.expiry_choices + 1] = s
    end
end
if #_M.expiry_choices == 0 then _M.expiry_choices = { _M.default_expiry } end

return _M
