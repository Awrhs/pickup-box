-- HMAC-SHA256 and constant-time comparison on top of resty.sha256.
local bit = require "bit"
local sha256 = require "resty.sha256"
local to_hex = require("resty.string").to_hex

local _M = {}

local BLOCK = 64

local function digest(data)
    local h = sha256:new()
    h:update(data)
    return h:final()
end

local ipad_cache, opad_cache = {}, {}

local function pads(key)
    local ip, op = ipad_cache[key], opad_cache[key]
    if ip then return ip, op end
    local k = key
    if #k > BLOCK then k = digest(k) end
    k = k .. string.rep("\0", BLOCK - #k)
    local i_t, o_t = {}, {}
    for i = 1, BLOCK do
        local b = k:byte(i)
        i_t[i] = string.char(bit.bxor(b, 0x36))
        o_t[i] = string.char(bit.bxor(b, 0x5c))
    end
    ip, op = table.concat(i_t), table.concat(o_t)
    ipad_cache[key], opad_cache[key] = ip, op
    return ip, op
end

-- Raw 32-byte HMAC-SHA256(key, msg).
function _M.hmac_sha256(key, msg)
    local ip, op = pads(key)
    return digest(op .. digest(ip .. msg))
end

function _M.hmac_sha256_hex(key, msg)
    return to_hex(_M.hmac_sha256(key, msg))
end

function _M.sha256_hex(data)
    return to_hex(digest(data))
end

-- Constant-time string equality (length is not secret).
function _M.const_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end

return _M
