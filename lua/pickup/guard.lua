-- Brute-force throttling for guessable inputs (pickup codes, share links,
-- passwords). Failures are counted per client IP in a shared dict with a
-- fixed window from the first failure; pickup codes also have a global
-- ceiling so a botnet cannot sweep the code space.
local client_ip = require "image.client_ip"
local pconfig = require "pickup.config"
local ngx = ngx

local _M = {}

local WINDOW = { code = 3600, auth = 900 }

local function limit(kind)
    if kind == "auth" then return pconfig.auth_fail_limit end
    return pconfig.code_fail_limit
end

-- True when this client (or, for codes, everyone) has failed too often.
function _M.blocked(kind)
    local dict = ngx.shared.pickup_guard
    if not dict then return false end
    local ip = client_ip.get()
    if (dict:get(kind .. ":" .. ip) or 0) >= limit(kind) then return true end
    if kind == "code" and (dict:get("code:global") or 0) >= pconfig.code_fail_global then
        return true
    end
    return false
end

function _M.fail(kind)
    local dict = ngx.shared.pickup_guard
    if not dict then return end
    local ip = client_ip.get()
    require("common.metrics").incr(kind == "auth" and "auth_failures" or "pickup_code_failures")
    dict:incr(kind .. ":" .. ip, 1, 0, WINDOW[kind] or 3600)
    if kind == "code" then dict:incr("code:global", 1, 0, 3600) end
end

-- Seconds a blocked client should wait (upper bound).
function _M.retry_after(kind)
    return WINDOW[kind] or 3600
end

return _M
