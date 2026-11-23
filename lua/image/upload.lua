-- Multipart upload handler. The file is streamed straight to a temporary
-- directory via FFI write(2); once on disk we validate the magic bytes, hash
-- it, and move it atomically into content-addressed storage. This keeps
-- multi-megabyte uploads out of the Lua heap entirely.
--
-- The same post-spool pipeline is reused by the tus 1.0 protocol (tus.lua)
-- via _M.finalize().
local config = require "image.config"
local util = require "image.util"
local storage = require "image.storage"
local metadata = require "image.metadata"
local spool = require "image.upload_spool"
local vips = require "image.vips_ffi"
local processing = require "image.processing"
local logger = require "common.logger"
local metrics = require "common.metrics"
local rate_limit = require "common.rate_limit"
local ngx = ngx

local _M = {}

-- Hash a file in chunks via the FFI libc so we do not have to slurp it into
-- Lua memory. Returns hex sha256 or nil, err.
local function hash_file_chunked(path)
    local ffi = require "ffi"
    local C = ffi.C
    local O_RDONLY = 0
    local fd = C.open(path, O_RDONLY, 0)
    if fd < 0 then return nil, "open failed" end

    local resty_sha = require "resty.sha256"
    local h = resty_sha:new()
    local BUF = 64 * 1024
    local buf = ffi.new("char[?]", BUF)
    local total = 0
    while true do
        local n = tonumber(C.read(fd, buf, BUF))
        if n < 0 then C.close(fd); return nil, "read failed" end
        if n == 0 then break end
        h:update(ffi.string(buf, n))
        total = total + n
    end
    C.close(fd)
    return require "resty.string".to_hex(h:final()), total
end

-- Shared post-spool pipeline: validate magic bytes, hash, get dimensions,
-- place in storage, check quota, insert metadata, pregenerate, compute
-- phash, and build the standard 201 JSON response fields.
--
-- `tmp` — path to the assembled file on disk (will be consumed by place_orig)
-- `filename` — original filename from upload metadata
-- `subject` — resolved API key record { name, hash, role, quota }
-- `cleanup` — optional function called before error exits (e.g. to unlink tmp)
--
-- On success: calls ngx.exit(201) with JSON body (does NOT return).
-- On quota/exceeded failure: calls the appropriate ngx.exit.
-- On other errors: calls util.*_error which exits.
-- To callers that need the response fields without an ngx.exit flow (tus),
-- pass `no_exit = true` — the function returns the response table and does
-- NOT exit; the caller must ngx.exit().
function _M.finalize(tmp, filename, subject, cleanup, no_exit)
    local fs = require "image.fs_ffi"
    local og_cleanup = cleanup
    cleanup = function()
        if og_cleanup then og_cleanup() end
        pcall(fs.unlink, tmp)
    end
    local function bail(status, msg)
        cleanup()
        if no_exit then return nil, msg end
        util.bad_request(msg)  -- calls ngx.exit
    end

    -- Validate strictly by magic bytes (never trust the extension).
    local head = fs.read_head(tmp, 64)
    if not head then return bail(400, "cannot read temp file") end
    local fmt, mime = util.detect_format(head)
    if not fmt or not config.allowed_formats[fmt] then
        return bail(400, "unsupported or unrecognized image format")
    end
    local ext = fmt == "jpeg" and "jpg" or fmt

    -- Hash the file content (chunked).
    local hash, size_or_err = hash_file_chunked(tmp)
    if not hash then
        cleanup()
        logger.err("hash_file_failed", { error = size_or_err })
        if no_exit then return nil, "hash failed" end
        util.server_error("hash failed")
    end

    -- Read width/height from file header.
    local width, height
    if vips.available() then
        local w, h = vips.dimensions_file(tmp)
        if not w then return bail(400, "cannot decode image") end
        width, height = w, h
        if (width * height) > config.max_pixels then
            return bail(400, "image too large in pixels")
        end
    end

    -- Publish into content-addressed storage.
    local final, existed = storage.place_orig(tmp, hash, ext)
    if not final then
        cleanup()
        logger.err("storage_place_failed", { error = tostring(existed) })
        if no_exit then return nil, "storage error" end
        util.server_error("storage error")
    end

    -- Insert with quota.
    local deduped = existed
    if not existed then
        local quota = subject.quota or config.default_quota_bytes
        local rowid, reason = metadata.insert_with_quota({
            hash = hash, orig_ext = ext, mime = mime,
            size_bytes = size_or_err,
            width = width, height = height,
            uploaded_by = subject.hash,
        }, quota)
        if reason == "dedup" then
            deduped = true
        elseif not rowid then
            storage.delete_orig(hash, ext)
            if reason == "quota" then
                if no_exit then return nil, "quota" end
                ngx.status = 413; ngx.header.content_type = "text/plain"
                ngx.say("413 Payload Too Large - quota exceeded"); ngx.exit(413)
            end
            logger.err("metadata_insert_failed", { error = tostring(reason) })
            if no_exit then return nil, "metadata error" end
            util.server_error("metadata error")
        end
    end

    metrics.incr_image_upload()

    -- Async pre-generation and pHash on new uploads.
    if not deduped then
        local pregen = require "image.pregenerator"
        pregen.schedule_file(final, hash, ext)

        -- Best-effort phash.
        if config.phash_enabled then
            local phash, perr = processing.phash_file(final)
            if phash then
                metadata.set_phash(hash, phash)
                -- (similar_to annotation skipped in shared path since the
                -- response is already generic; callers who want it can add)
            end
        end
    end

    -- Build response fields.
    local base = ngx.var.scheme .. "://" .. ngx.var.host
    local plain = base .. "/i/" .. hash
    local with_ext = plain .. "." .. ext
    local md = "![" .. (filename or hash) .. "](" .. with_ext .. ")"
    local html = '<img src="' .. with_ext .. '" alt="' .. (filename or hash) .. '">'

    local resp = {
        hash = hash, url = with_ext, url_plain = plain,
        markdown = md, html = html,
        filename = filename, mime = mime,
        size = size_or_err, width = width, height = height,
        deduped = deduped,
    }
    local slug = metadata.ensure_slug(hash)
    if slug then
        resp.short_url = (base .. "/s/" .. slug)
        resp.slug = slug
    end

    if no_exit then return resp end

    ngx.status = 201
    ngx.header.content_type = "application/json"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode(resp))
    ngx.exit(201)
end

-- POST /upload (multipart/form-data entry point).
function _M.handle(subject)
    if not rate_limit.check_upload_limit(subject.hash) then
        rate_limit.block_request("upload_rate_limit_exceeded")
    end

    local ct = ngx.var.http_content_type or ""
    if not ct:lower():find("multipart/form-data", 1, true) then
        util.bad_request("Content-Type must be multipart/form-data")
    end

    local tmp = config.tmp_dir .. "/upload-" .. ngx.worker.pid() .. "-"
        .. ngx.time() .. ".bin"

    local res, serr = spool.spool_file(tmp, config.max_upload_bytes)
    if not res then
        util.bad_request(serr or "invalid upload")
    end

    _M.finalize(tmp, res.filename, subject)
end

return _M