-- Resolve the real client IP, taking X-Forwarded-For into account only when
-- TRUST_X_FORWARDED_FOR is enabled and with a configured number of trusted
-- proxy hops. This prevents a random internet client from spoofing XFF to
-- evade per-IP rate limits.
--
--   TRUST_X_FORWARDED_FOR=true
--   IMAGE_TRUSTED_PROXY_HOPS=1   (default: 1; set to the number of proxy
--                                      layers in front of the gateway)
--
-- Without trust enabled we always use $remote_addr (the actual TCP peer).
local ngx = ngx
local os = os
local _M = {}

local trusted = os.getenv("TRUST_X_FORWARDED_FOR") == "true"
              or os.getenv("TRUST_X_FORWARDED_FOR") == "1"
local hops = tonumber(os.getenv("IMAGE_TRUSTED_PROXY_HOPS")) or 1

-- Return the client IP as a string. Never returns nil (falls back to
-- "unknown"). When XFF is trusted but malformed/absent, falls back to
-- remote_addr so limits still apply.
function _M.get()
    if trusted then
        local xff = ngx.var.http_x_forwarded_for
        if xff and xff ~= "" then
            -- XFF is "client, proxy1, proxy2, ..." appended left-to-right.
            -- With N trusted hops, take the Nth-from-the-right address that
            -- is not our own.
            local addrs = {}
            for v in xff:gmatch("[^,]+") do
                local v2 = v:gsub("^%s+", ""):gsub("%s+$", "")
                if v2 ~= "" then addrs[#addrs + 1] = v2 end
            end
            if #addrs >= hops then
                return addrs[#addrs - hops + 1]
            end
            if #addrs > 0 then return addrs[1] end
        end
    end
    return ngx.var.remote_addr or "unknown"
end

-- Anonymized hash of the client IP, suitable for shared-dict keys and logs.
local resty_sha256 = require "resty.sha256"
local to_hex = require "resty.string".to_hex
function _M.hashed(salt)
    local ip = _M.get()
    local h = resty_sha256:new()
    h:update(salt or "")
    h:update("|")
    h:update(ip)
    return to_hex(h:final()):sub(1, 32), ip
end

return _M
