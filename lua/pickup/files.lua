-- Serving the contents of a share: single files (through nginx sendfile with
-- Range support), image thumbnails, a streamed zip of everything, and the QR
-- code of the share link.
local storage = require "image.storage"
local fs = require "image.fs_ffi"
local transform = require "image.transform"
local metadata = require "image.metadata"
local errors = require "image.errors"
local shares = require "pickup.shares"
local sniff = require "pickup.sniff"
local zip = require "pickup.zip"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

-- Content-Disposition with an ASCII fallback plus the RFC 5987 UTF-8 name.
function _M.disposition(kind, name)
    local ascii = name:gsub('[^%w%.%-_ ()%[%]]', "_")
    if ascii:gsub("_", "") == "" then ascii = "download" end
    local encoded = name:gsub("[^%w%.%-_~]", function(c)
        return string.format("%%%02X", c:byte())
    end)
    return ('%s; filename="%s"; filename*=UTF-8\'\'%s'):format(kind, ascii, encoded)
end

local function gone(msg)
    errors.respond(410, msg or "文件已被清理 (file no longer available)")
end

-- Share-level gate for file/thumbnail/zip requests. Visit-limited shares
-- require the access token minted when the pickup page was opened.
function _M.authorize(share)
    local st = shares.state(share)
    if st == "revoked" then errors.respond(410, "发送者已撤回这个分享 (share revoked)") end
    if st == "expired" then errors.respond(410, "这个分享已过期 (share expired)") end
    if (tonumber(share.max_visits) or 0) > 0 then
        local t = ngx.var.arg_t
        if not shares.verify_token(share, t) then
            errors.respond(403, "请从取件页面打开 (open the pickup page first)")
        end
    end
end

local function blob_path(f)
    if not f or not f.orig_ext then return nil end
    local path = storage.orig_path(f.blob_hash, f.orig_ext)
    if not fs.exists(path) then return nil end
    return path
end

-- GET /p/<slug>/f/<seq>[?dl=1]
function _M.serve_file(share, f)
    local path = blob_path(f)
    if not path then return gone() end
    local download = ngx.var.arg_dl == "1" or not sniff.INLINE[f.kind]
    ngx.header["Content-Type"] = f.mime
    ngx.header["Content-Disposition"] = _M.disposition(download and "attachment" or "inline", f.name)
    -- Inline media are rendered in a sandbox; attachments are never
    -- rendered, and WebKit refuses to download a sandboxed response.
    ngx.header["Content-Security-Policy"] = download and "default-src 'none'"
        or "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox"
    ngx.header["Cache-Control"] = "private, no-cache"
    ngx.ctx.pb_bytes_file = true
    return ngx.exec(storage.to_internal_uri(path))
end

local THUMB_WIDTH = { s = 320, l = 1280 }

-- GET /p/<slug>/f/<seq>/thumb?s=s|l  (images only; fixed sizes so links
-- cannot be used to make the server render arbitrary variants)
function _M.serve_thumb(share, f)
    if f.kind ~= "image" or not blob_path(f) then
        return errors.respond(404, "no preview")
    end
    local width = THUMB_WIDTH[ngx.var.arg_s or "s"] or THUMB_WIDTH.s
    local accept = ngx.var.http_accept or ""
    local params = {
        width = width, height = 0, crop = false, quality = 82,
        format = accept:find("image/webp", 1, true) and "webp" or "jpeg",
        watermark = false, grayscale = false, blur = 0, noop = false,
    }
    ngx.ctx.pb_private_cache = true
    ngx.header["Vary"] = "Accept"
    return transform.serve(f.blob_hash, nil, params)
end

-- GET /p/<slug>/zip
function _M.serve_zip(share, files)
    local entries, paths = {}, {}
    for i, f in ipairs(files) do
        local path = blob_path(f)
        if not path then return gone("部分文件已被清理，无法打包 (some files are gone)") end
        local crc = tonumber(f.crc32)
        if not crc then
            local d = require("image.processing").digest_file(path)
            if not d then return errors.respond(500, "cannot read file") end
            crc = d.crc32
            pcall(metadata.write, function(db)
                db:run("UPDATE images SET crc32=? WHERE hash=?", crc, f.blob_hash)
            end)
        end
        entries[i] = { name = f.name, size = tonumber(f.size_bytes), crc32 = crc }
        paths[i] = path
    end

    local plan = zip.plan(entries, { mtime = tonumber(share.created_at),
                                     force_zip64 = ngx.var.arg_zip64 == "1" })
    local base = (share.title ~= "" and share.title) or ("files-" .. share.slug)
    ngx.header["Content-Type"] = "application/zip"
    ngx.header["Content-Disposition"] = _M.disposition("attachment", base .. ".zip")
    ngx.header["Content-Length"] = tostring(plan.total)
    ngx.header["Cache-Control"] = "private, no-store"
    if ngx.req.get_method() == "HEAD" then return ngx.exit(200) end

    local CHUNK = 256 * 1024
    local buf = require("ffi").new("char[?]", CHUNK)
    local sent = 0
    for i, e in ipairs(plan.entries) do
        ngx.print(e.header)
        local fd, oerr = fs.open_read(paths[i])
        if not fd then
            logger.err("zip_open_failed", { path = paths[i], error = tostring(oerr) })
            return ngx.exit(ngx.ERROR)
        end
        local left = e.size
        while left > 0 do
            local data, rerr = fs.read_fd(fd, left < CHUNK and left or CHUNK, buf)
            if not data or data == "" then
                fs.close(fd)
                logger.err("zip_read_failed", { path = paths[i], error = tostring(rerr) })
                return ngx.exit(ngx.ERROR)
            end
            ngx.print(data)
            left = left - #data
            sent = sent + #data
            local ok = ngx.flush(true)
            if not ok then fs.close(fd); return ngx.exit(ngx.ERROR) end  -- client went away
        end
        fs.close(fd)
    end
    ngx.print(plan.trailer)
    ngx.ctx.pb_zip_bytes = plan.total
    return ngx.exit(200)
end

-- GET /p/<slug>/qr.svg
function _M.serve_qr(share)
    local qr = require "pickup.qr"
    local svg = qr.available() and qr.svg(shares.public_url("/p/" .. share.slug))
    if not svg then return errors.respond(404, "QR not available") end
    ngx.header["Content-Type"] = "image/svg+xml"
    ngx.header["Cache-Control"] = "private, max-age=3600"
    ngx.header["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
    ngx.print(svg)
    return ngx.exit(200)
end

return _M
