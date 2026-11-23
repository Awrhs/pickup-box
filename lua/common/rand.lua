-- Cryptographically secure random helpers (OpenSSL RAND_bytes through
-- resty.random). Used for share slugs, pickup codes, upload session IDs and
-- the generated server secret; never use math.random for these.
local _M = {}

local BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

-- `n` strong random bytes as a Lua string. Raises if the CSPRNG fails.
function _M.bytes(n)
    local b = require("resty.random").bytes(n, true)
    if not b then error("CSPRNG unavailable") end
    return b
end

function _M.hex(nbytes)
    return require("resty.string").to_hex(_M.bytes(nbytes))
end

-- Uniform string over `alphabet` using rejection sampling (no modulo bias).
local function uniform(alphabet, len)
    local k = #alphabet
    local limit = 256 - (256 % k)  -- accept bytes < limit
    local out = {}
    while #out < len do
        local raw = _M.bytes(len * 2)
        for i = 1, #raw do
            local v = raw:byte(i)
            if v < limit then
                local idx = (v % k) + 1
                out[#out + 1] = alphabet:sub(idx, idx)
                if #out == len then break end
            end
        end
    end
    return table.concat(out)
end

function _M.base62(len) return uniform(BASE62, len) end
function _M.digits(len) return uniform("0123456789", len) end

return _M
