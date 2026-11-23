-- Streaming "store" (uncompressed) zip writer with ZIP64 support.
--
-- Sizes and CRC-32s are known up front (computed at upload time), so every
-- header can be written before its data, the exact archive length is known
-- (Content-Length, resumable progress bars) and no temp file is needed.
-- Photos and videos are already compressed, so "store" costs nothing.
local bit = require "bit"

local _M = {}

local U32_MAX = 0xFFFFFFFF
local U16_MAX = 0xFFFF

local function u16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function u64(n)
    local lo = n % 4294967296
    local hi = math.floor(n / 4294967296)
    return u32(lo) .. u32(hi)
end
_M._u16, _M._u32, _M._u64 = u16, u32, u64

-- MS-DOS date/time (local fields of a UTC timestamp; zip has no zones).
local function dos_time(ts)
    local t = os.date("!*t", ts)
    if t.year < 1980 then t = { year = 1980, month = 1, day = 1, hour = 0, min = 0, sec = 0 } end
    local time = t.hour * 2048 + t.min * 32 + math.floor(t.sec / 2)
    local date = (t.year - 1980) * 512 + t.month * 32 + t.day
    return time, date
end

-- entries: array of { name = utf8 string, size = bytes, crc32 = number }
-- opts.mtime: timestamp for all entries; opts.force_zip64: for testing.
-- Returns a plan: { entries = { { header = string, size = n } ... },
--                   trailer = string, total = n }
function _M.plan(entries, opts)
    opts = opts or {}
    local time, date = dos_time(opts.mtime or os.time())
    local force = opts.force_zip64
    local offset = 0
    local out, central = {}, {}

    for _, e in ipairs(entries) do
        local size = e.size
        local name = e.name
        local local_zip64 = force or size >= U32_MAX
        local extra = ""
        if local_zip64 then
            extra = u16(0x0001) .. u16(16) .. u64(size) .. u64(size)
        end
        local size32 = local_zip64 and U32_MAX or size
        local version = local_zip64 and 45 or 20
        local flags = 0x0800  -- names are UTF-8
        local header = u32(0x04034b50) .. u16(version) .. u16(flags) .. u16(0)
            .. u16(time) .. u16(date) .. u32(e.crc32) .. u32(size32) .. u32(size32)
            .. u16(#name) .. u16(#extra) .. name .. extra
        out[#out + 1] = { header = header, size = size }

        -- Central directory record; ZIP64 extra holds only the overflowed
        -- fields, in the order: uncompressed, compressed, local offset.
        local c_extra_fields = {}
        local c_size = size
        local c_offset = offset
        if force or size >= U32_MAX then
            c_extra_fields[#c_extra_fields + 1] = u64(size) .. u64(size)
            c_size = U32_MAX
        end
        if force or offset >= U32_MAX then
            c_extra_fields[#c_extra_fields + 1] = u64(offset)
            c_offset = U32_MAX
        end
        local c_extra = ""
        if #c_extra_fields > 0 then
            local body = table.concat(c_extra_fields)
            c_extra = u16(0x0001) .. u16(#body) .. body
        end
        local c_version = (#c_extra > 0) and 45 or 20
        central[#central + 1] = u32(0x02014b50)
            .. u16(bit.bor(3 * 256, 45))         -- made by: Unix, spec 4.5
            .. u16(c_version) .. u16(flags) .. u16(0)
            .. u16(time) .. u16(date) .. u32(e.crc32)
            .. u32(c_size) .. u32(c_size)
            .. u16(#name) .. u16(#c_extra) .. u16(0)   -- name, extra, comment
            .. u16(0) .. u16(0)                          -- disk, internal attrs
            .. u32(0x81A40000)                           -- -rw-r--r-- regular file
            .. u32(c_offset) .. name .. c_extra

        offset = offset + #header + size
    end

    local cd = table.concat(central)
    local cd_offset, cd_size, count = offset, #cd, #entries
    local trailer = { cd }
    local need64 = force or count >= U16_MAX or cd_offset >= U32_MAX or cd_size >= U32_MAX
    if need64 then
        local z64_offset = cd_offset + cd_size
        trailer[#trailer + 1] = u32(0x06064b50) .. u64(44) .. u16(45) .. u16(45)
            .. u32(0) .. u32(0) .. u64(count) .. u64(count) .. u64(cd_size) .. u64(cd_offset)
        trailer[#trailer + 1] = u32(0x07064b50) .. u32(0) .. u64(z64_offset) .. u32(1)
    end
    trailer[#trailer + 1] = u32(0x06054b50) .. u16(0) .. u16(0)
        .. u16(need64 and U16_MAX or count) .. u16(need64 and U16_MAX or count)
        .. u32(need64 and U32_MAX or cd_size) .. u32(need64 and U32_MAX or cd_offset)
        .. u16(0)
    local trailer_s = table.concat(trailer)

    return { entries = out, trailer = trailer_s, total = offset + #trailer_s }
end

return _M
