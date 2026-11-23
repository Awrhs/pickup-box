-- Small utilities for the image hosting subsystem.
local sha256 = require "resty.sha256"
local to_hex = require "resty.string".to_hex
local ffi = require "ffi"
local bit = require "bit"
local config = require "image.config"
local storage = require "image.storage"

local _M = {}

-- SHA-256 hex digest of a string.
function _M.sha256_hex(data)
    local h = sha256:new()
    h:update(data)
    return to_hex(h:final())
end

-- Detect image type from magic bytes. Returns a canonical format name
-- (jpeg/png/gif/webp/avif) and mime, or nil.
local MAGIC = {
    jpeg = { "\255\216\255" },          -- FFD8FF
    png  = { "\137\080\078\071\013\010\026\010" },
    gif  = { "GIF87a", "GIF89a" },
    webp = { "RIFF" },                   -- plus check "WEBP" at offset 8
}

function _M.detect_format(data)
    if #data < 12 then return nil end

    if data:sub(1, 3) == MAGIC.jpeg[1] then
        return "jpeg", config.mime.jpeg
    end
    if data:sub(1, 8) == MAGIC.png[1] then
        return "png", config.mime.png
    end
    if data:sub(1, 6) == MAGIC.gif[1] or data:sub(1, 6) == MAGIC.gif[2] then
        return "gif", config.mime.gif
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return "webp", config.mime.webp
    end
    -- ftyp box check for AVIF/HEIF: bytes 4..8 == "ftyp", brand at 8..12
    if #data >= 12 and data:sub(5, 8) == "ftyp" then
        local brand = data:sub(9, 12)
        if brand == "avif" or brand == "avis" then
            return "avif", config.mime.avif
        end
    end
    return nil
end

-- Safe integer parsing for query params, with bounds and default.
function _M.parse_int(v, default, min, max)
    local n = tonumber(v)
    if not n or n ~= math.floor(n) then return default end
    if min and n < min then return min end
    if max and n > max then return max end
    return n
end

-- Format canonicalization for output.
function _M.canonical_format(fmt)
    if not fmt then return nil end
    fmt = string.lower(fmt)
    if fmt == "jpg" then fmt = "jpeg" end
    if config.output_formats[fmt] then return fmt end
    return nil
end

-- Detect whether an encoded image is animated.
--   * GIF: all multi-frame GIFs are "animated"; a single-frame GIF is not.
--   * WebP: inspect the VP8X chunk's flags bit 1 (ANIM).
-- We intentionally do not try to detect animated PNG/AVIF here — those are
-- rare in the wild and the cost/benefit is poor.
-- Detect an animated GIF/WebP from a head prefix (caller should pass at least
-- the first 1024 bytes for GIF, 32 bytes for WebP).
function _M.is_animated(data, fmt)
    if fmt == "gif" then
        -- The NETSCAPE2.0 / ANIMEXTS1.0 application extension is only
        -- present in animated GIFs (it carries the loop count). Search the
        -- prefix for either marker.
        if data:find("NETSCAPE2%.0", 1, false)
           or data:find("ANIMEXTS1%.0", 1, false) then
            return true
        end
        return false
    end
    if fmt == "webp" then
        if #data >= 31 and data:sub(1, 4) == "RIFF"
           and data:sub(9, 12) == "WEBP"
           and data:sub(13, 16) == "VP8X" then
            -- Flags at byte offset 24 (0-indexed), i.e. Lua position 25;
            -- the ANIM flag is bit 0x02.
            local b = string.byte(data, 25)
            if b and bit.band(b, 0x02) ~= 0 then return true end
        end
        return false
    end
    return false
end

-- Deterministic cache key for a transform request. SINGLE SOURCE OF TRUTH:
-- both the serving path (transform.serve) and the async pre-generator
-- (pregenerator.lua) must call this function so a pre-generated derivative is
-- found by the live path byte-for-byte.
--
-- `params` is the table produced by parse_transform_args (or an equivalent
-- canonical table with the same fields); `out_fmt` is the output format or
-- nil to keep the original encoding. The watermark file's byte size acts as
-- a cheap version so swapping the watermark PNG invalidates derivatives.
function _M.cache_key(params, out_fmt)
    local parts = {
        "w" .. params.width,
        "h" .. params.height,
        params.crop and "c1" or "c0",
        "q" .. params.quality,
        "f" .. (out_fmt or "orig"),
        params.watermark and "wm1" or "wm0",
        params.grayscale and "g1" or "g0",
        "b" .. tostring(params.blur or 0),
    }
    if params.watermark and config.watermark_path then
        parts[#parts + 1] = "wv" .. tostring(storage.size(config.watermark_path) or 0)
    end

    -- Text watermark. The short hash (first 8 hex chars of sha256 of text)
    -- plus font params enters the key so we do not need to tokenise every
    -- possible CSS escape in the filename.
    if params.watermark_text then
        local text_hash = _M.sha256_hex(params.watermark_text):sub(1, 8)
        parts[#parts + 1] = "tx" .. text_hash
        parts[#parts + 1] = "ts" .. tostring(params.watermark_font_size)
        if params.watermark_text_color_hex then
            parts[#parts + 1] = "tc" .. params.watermark_text_color_hex
        end
        if config.text_font_path then
            local fv = storage.size(config.text_font_path) or 0
            parts[#parts + 1] = "fv" .. tostring(fv)
        end
    end

    return table.concat(parts, "_")
end

-- Hamming distance (in bits) between two 16-character hex strings.
-- Used by the pHash similar-image scan in upload.lua.
function _M.hamming_distance(hex_a, hex_b)
    if not hex_a or not hex_b or #hex_a ~= 16 or #hex_b ~= 16 then return 64 end
    local bit = require "bit"
    local diff = 0
    for i = 1, 16 do
        local na = tonumber(hex_a:sub(i,i), 16) or 0
        local nb = tonumber(hex_b:sub(i,i), 16) or 0
        local x = bit.bxor(na, nb)
        while x > 0 do
            diff = diff + bit.band(x, 1)
            x = bit.rshift(x, 1)
        end
    end
    return diff
end

-- HTML-escape a string for safe interpolation into templates.
function _M.html_escape(s)
    if s == nil then return "" end
    s = tostring(s)
    return (s:gsub('[&<>"\']', {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

-- Human-readable byte size (e.g. 1536 -> "1.5 KiB").
function _M.human_size(bytes)
    if bytes < 1024 then return tostring(bytes) .. " B" end
    local units = { "KiB", "MiB", "GiB", "TiB" }
    local value = bytes / 1024
    for i = 1, #units do
        if value < 1024 or i == #units then
            return string.format("%.1f %s", value, units[i])
        end
        value = value / 1024
    end
    return string.format("%.1f TiB", value)
end

-- Content-negotiated error helpers. Prefer these over plain text/plain so
-- HTML clients see a styled page and API clients get JSON.
local function err(status, default_msg, message)
    require "image.errors".respond(status, message or default_msg)
end

function _M.server_error(message) err(500, "internal error", message) end
function _M.bad_request(message) err(400, "bad request", message) end
function _M.not_found(message)   err(404, "not found", message) end
function _M.forbidden(message)   err(403, "forbidden", message) end

-- Read an entire request body into a Lua string (with size guard).
function _M.read_body(max_bytes)
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if data then
        if #data > max_bytes then
            return nil, "body too large"
        end
        return data, nil
    end
    -- Body was spooled to disk; read the file via FFI.
    local path = ngx.req.get_body_file()
    if not path then
        return nil, "no body"
    end
    local fs = require "image.fs_ffi"
    local size = fs.file_size(path)
    if not size or size > max_bytes then
        return nil, "body too large or unreadable"
    end
    return fs.read_file(path)
end

-- Validate/normalize the image output parameters from query string.
-- Returns a params table or nil + error.
function _M.parse_transform_args()
    local args = ngx.req.get_uri_args()
    local p = {
        width = 0,
        height = 0,
        crop = false,
        quality = 82,
        format = nil,       -- nil means keep original
        watermark = false,
        grayscale = false,
        blur = 0,
        noop = true,        -- becomes false if any transform is requested
    }

    if args.w and args.w ~= "" then
        local w = _M.parse_int(args.w, nil, 1, 10000)
        if not w then return nil, "invalid width" end
        p.width = w; p.noop = false
    end
    if args.h and args.h ~= "" then
        local h = _M.parse_int(args.h, nil, 1, 10000)
        if not h then return nil, "invalid height" end
        p.height = h; p.noop = false
    end

    local fit = args.fit or "fit"
    if fit == "cover" or fit == "crop" then
        p.crop = true; p.noop = false
    end

    if args.q and args.q ~= "" then
        p.quality = _M.parse_int(args.q, 82, 1, 100)
        p.noop = false
    end

    if args.fmt and args.fmt ~= "" then
        local fmt = _M.canonical_format(args.fmt)
        if not fmt then return nil, "unsupported format" end
        p.format = fmt
        p.noop = false
    end

    if args.wm == "1" or args.watermark == "1" then
        p.watermark = true
        p.noop = false
    end

    if args.gray == "1" or args.grayscale == "1" or args.greyscale == "1" then
        p.grayscale = true
        p.noop = false
    end

    if args.blur and args.blur ~= "" then
        local b = tonumber(args.blur)
        if not b or b < 0 or b > 50 then
            return nil, "invalid blur (0..50)"
        end
        if b > 0 then p.blur = b; p.noop = false end
    end

    -- Text watermark params (wmt = UTF-8 text, wms = font size, wmc = RRGGBB hex)
    p.watermark_text = nil
    p.watermark_font_size = 0
    p.watermark_text_color_hex = nil
    if args.wmt and args.wmt ~= "" then
        -- Cap text at 200 bytes and strip control characters for safety.
        local safe = tostring(args.wmt):sub(1, 200):gsub("[%z\1-\31]", "")
        if #safe > 0 then
            p.watermark_text = safe
            p.noop = false
        end
    end
    if args.wms and args.wms ~= "" then
        local s = _M.parse_int(args.wms, 0, 8, 512)
        if s then p.watermark_font_size = s end
    end
    if args.wmc and args.wmc ~= "" then
        local hex = args.wmc:gsub("[^0-9a-fA-F]", "")
        if #hex == 6 then
            p.watermark_text_color_hex = hex
            p.noop = false
        end
    end

    return p
end

return _M
