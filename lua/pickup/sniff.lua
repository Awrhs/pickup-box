-- Content sniffing by magic bytes. The uploaded file name is never trusted
-- for anything security relevant: `kind` decides whether a file may be shown
-- inline (image/video/audio players) or is always served as a download.
local bit = require "bit"

local _M = {}

local IMAGE_MIME = {
    jpeg = "image/jpeg", png = "image/png", gif = "image/gif",
    webp = "image/webp", avif = "image/avif", heic = "image/heic",
}

local HEIC_BRANDS = { heic = 1, heix = 1, hevc = 1, heim = 1, heis = 1, hevm = 1, hevs = 1, mif1 = 1, msf1 = 1 }
local MP4_BRANDS = {
    isom = 1, iso2 = 1, iso4 = 1, iso5 = 1, iso6 = 1, mp41 = 1, mp42 = 1, avc1 = 1,
    ["M4V "] = 1, M4VH = 1, M4VP = 1, dash = 1, ["3gp4"] = 1, ["3gp5"] = 1, ["3gp6"] = 1,
    ["3g2a"] = 1, MSNV = 1, ["f4v "] = 1, mmp4 = 1,
}

-- Returns kind, fmt, mime, ext.
--   kind: "image" | "video" | "audio" | "other"
--   ext:  canonical storage extension derived from content ("bin" for other)
function _M.classify(head)
    head = head or ""
    local n = #head
    if n >= 3 and head:sub(1, 3) == "\255\216\255" then
        return "image", "jpeg", IMAGE_MIME.jpeg, "jpg"
    end
    if n >= 8 and head:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "image", "png", IMAGE_MIME.png, "png"
    end
    if n >= 6 and (head:sub(1, 6) == "GIF87a" or head:sub(1, 6) == "GIF89a") then
        return "image", "gif", IMAGE_MIME.gif, "gif"
    end
    if n >= 12 and head:sub(1, 4) == "RIFF" then
        local sub = head:sub(9, 12)
        if sub == "WEBP" then return "image", "webp", IMAGE_MIME.webp, "webp" end
        if sub == "WAVE" then return "audio", "wav", "audio/wav", "wav" end
        return "other", nil, "application/octet-stream", "bin"
    end
    if n >= 12 and head:sub(5, 8) == "ftyp" then
        local brand = head:sub(9, 12)
        if brand == "avif" or brand == "avis" then return "image", "avif", IMAGE_MIME.avif, "avif" end
        if HEIC_BRANDS[brand] then return "image", "heic", IMAGE_MIME.heic, "heic" end
        if brand == "qt  " then return "video", "mov", "video/quicktime", "mov" end
        if brand == "M4A " or brand == "M4B " then return "audio", "m4a", "audio/mp4", "m4a" end
        if MP4_BRANDS[brand] then return "video", "mp4", "video/mp4", "mp4" end
        return "other", nil, "application/octet-stream", "bin"
    end
    if n >= 4 and head:sub(1, 4) == "\26\69\223\163" then  -- EBML: webm/mkv
        if head:find("webm", 1, true) then return "video", "webm", "video/webm", "webm" end
        return "video", "mkv", "video/x-matroska", "mkv"
    end
    if n >= 3 and head:sub(1, 3) == "ID3" then return "audio", "mp3", "audio/mpeg", "mp3" end
    -- Bare MPEG audio frame sync (11 bits) with layer III; this excludes the
    -- UTF-16 byte-order mark FF FE.
    if n >= 2 and head:byte(1) == 0xFF and bit.band(head:byte(2), 0xE0) == 0xE0
       and bit.band(head:byte(2), 0x06) == 0x02 then
        return "audio", "mp3", "audio/mpeg", "mp3"
    end
    if n >= 4 and head:sub(1, 4) == "fLaC" then return "audio", "flac", "audio/flac", "flac" end
    if n >= 4 and head:sub(1, 4) == "OggS" then return "audio", "ogg", "audio/ogg", "ogg" end
    return "other", nil, "application/octet-stream", "bin"
end

-- MIME type for a download, from the (untrusted) file name. Only used for the
-- Content-Type of "other" files, which are always sent as attachments.
local EXT_MIME = {
    pdf = "application/pdf", zip = "application/zip", txt = "text/plain",
    doc = "application/msword", docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    xls = "application/vnd.ms-excel", xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ppt = "application/vnd.ms-powerpoint", pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    apk = "application/vnd.android.package-archive", rar = "application/vnd.rar", ["7z"] = "application/x-7z-compressed",
    csv = "text/csv", json = "application/json", epub = "application/epub+zip",
}

function _M.mime_for_name(name)
    local ext = (name or ""):match("%.([%w]+)$")
    return ext and EXT_MIME[ext:lower()] or "application/octet-stream"
end

-- Kinds the browser may render inline (served with a sandboxing CSP).
_M.INLINE = { image = true, video = true, audio = true }

-- Image formats libvips can turn into thumbnails.
_M.THUMBNAILABLE = { jpeg = true, png = true, gif = true, webp = true, avif = true, heic = true }

return _M
