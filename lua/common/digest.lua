-- Pure-Lua digests: CRC-32 (IEEE, as used by zip) and a streaming file
-- digest (SHA-256 + CRC-32 + size). The C helper (iv_digest_file) is the
-- fast path; this module is the fallback and the reference used by tests.
local bit = require "bit"
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift

local _M = {}

local TABLE = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if band(c, 1) == 1 then
            c = bxor(0xEDB88320, rshift(c, 1))
        else
            c = rshift(c, 1)
        end
    end
    TABLE[i] = c
end

-- Update a running CRC-32 with `s`. Start with crc = 0; returns an unsigned
-- 32-bit number (0 .. 2^32-1).
function _M.crc32(s, crc)
    local c = bxor(crc or 0, 0xFFFFFFFF)
    for i = 1, #s do
        c = bxor(TABLE[band(bxor(c, s:byte(i)), 0xFF)], rshift(c, 8))
    end
    c = bxor(c, 0xFFFFFFFF)
    if c < 0 then c = c + 4294967296 end
    return c
end

-- Digest a file: returns { sha256 = hex, crc32 = n, size = n } or nil, err.
function _M.file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local sha = require("resty.sha256"):new()
    local crc, size = 0, 0
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        sha:update(chunk)
        crc = _M.crc32(chunk, crc)
        size = size + #chunk
    end
    f:close()
    return { sha256 = require("resty.string").to_hex(sha:final()), crc32 = crc, size = size }
end

return _M
