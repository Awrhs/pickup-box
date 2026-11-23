-- Blob ingestion shared by the multipart API (/api/upload) and tus (/files/).
--
-- A fully received upload sits in a temp file; store() sniffs its type from
-- magic bytes, digests it (SHA-256 + CRC-32 on the OS thread pool), and moves
-- it into content-addressed storage. Identical content is stored once.
local config = require "image.config"
local storage = require "image.storage"
local metadata = require "image.metadata"
local spool = require "image.upload_spool"
local vips = require "image.vips_ffi"
local processing = require "image.processing"
local fs = require "image.fs_ffi"
local logger = require "common.logger"
local metrics = require "common.metrics"
local pconfig = require "pickup.config"
local sniff = require "pickup.sniff"
local ngx = ngx

local _M = {}

-- Per-blob mutual exclusion across workers (shared with the GC).
function _M.lock_blob(hash)
    local lock = require("resty.lock"):new("pickup_locks", { timeout = 30, exptime = 120 })
    local ok, err = lock:lock("blob:" .. hash)
    if not ok then return nil, err end
    return lock
end

-- Space left on the data volume after writing `incoming` more bytes must stay
-- above PICKUP_MIN_FREE_PERCENT of the disk.
function _M.disk_has_room(incoming)
    local total, avail = fs.disk_stats(config.data_dir)
    if not total or total == 0 then return true end
    local reserve = total * pconfig.min_free_percent / 100
    return (avail - (incoming or 0)) >= reserve
end

-- Quota left in the rolling window for a subject (nil = unlimited).
function _M.quota_left(subject)
    if subject.role == "admin" then return nil end
    local quota = subject.quota or pconfig.quota_bytes
    if not quota or quota <= 0 then return nil end
    local used = metadata.usage_for(subject.hash)
    return math.max(0, quota - used), quota, used
end

-- Turn a finished temp file into a stored blob.
-- Returns blob { hash, size, kind, fmt, mime, ext, width, height, crc32,
-- deduped } or nil, error_code, http_status. The temp file is always
-- consumed (moved or deleted).
function _M.store(tmp, subject)
    local function fail(code, status)
        fs.unlink(tmp)
        return nil, code, status
    end

    local head = fs.read_head(tmp, 64) or ""
    local kind, fmt, mime, ext = sniff.classify(head)

    local digest, derr = processing.digest_file(tmp)
    if not digest then
        logger.err("digest_failed", { error = tostring(derr) })
        return fail("digest_failed", 500)
    end
    local hash, size = digest.sha256, digest.size

    local width, height
    if kind == "image" then
        local w, h = vips.dimensions_file(tmp)
        if w and (w * h) <= config.max_pixels then
            width, height = w, h
        else
            -- Undecodable or oversized: still a valid file, just no previews.
            kind = "other"
        end
    end

    local lock, lerr = _M.lock_blob(hash)
    if not lock then
        logger.err("blob_lock_failed", { error = tostring(lerr) })
        return fail("busy", 503)
    end

    local existing = metadata.get_image(hash)
    if existing then
        local path = storage.orig_path(hash, existing.orig_ext)
        if fs.exists(path) then
            fs.unlink(tmp)
        else
            -- Row without file (e.g. disk restored from backup): repair.
            local placed, perr = storage.place_orig(tmp, hash, existing.orig_ext)
            if not placed then
                lock:unlock()
                logger.err("storage_place_failed", { error = tostring(perr) })
                return fail("storage_error", 500)
            end
        end
        metadata.touch_blob(hash)
        lock:unlock()
        return {
            hash = hash, size = tonumber(existing.size_bytes), kind = existing.kind or kind,
            mime = existing.mime, ext = existing.orig_ext, width = existing.width,
            height = existing.height, crc32 = existing.crc32 or digest.crc32, deduped = true,
        }
    end

    local final, perr = storage.place_orig(tmp, hash, ext)
    if not final then
        lock:unlock()
        logger.err("storage_place_failed", { error = tostring(perr) })
        return fail("storage_error", 500)
    end

    local quota = nil
    if subject.role ~= "admin" then quota = subject.quota or pconfig.quota_bytes end
    local rowid, reason = metadata.insert_with_quota({
        hash = hash, orig_ext = ext, mime = mime, size_bytes = size,
        width = width, height = height, uploaded_by = subject.hash,
        kind = kind, crc32 = digest.crc32,
    }, quota)
    if not rowid and reason ~= "dedup" then
        storage.delete_orig(hash, ext)
        lock:unlock()
        if reason == "quota" then return nil, "quota_exceeded", 413 end
        logger.err("metadata_insert_failed", { error = tostring(reason) })
        return nil, "metadata_error", 500
    end
    lock:unlock()

    metrics.incr_image_upload()
    if kind == "image" and sniff.THUMBNAILABLE[fmt] then
        require("image.pregenerator").schedule_file(final, hash, ext)
    end

    return {
        hash = hash, size = size, kind = kind, fmt = fmt, mime = mime, ext = ext,
        width = width, height = height, crc32 = digest.crc32, deduped = false,
    }
end

-- Public view of a stored blob for API responses.
function _M.describe(blob, name)
    return {
        hash = blob.hash, size = blob.size, kind = blob.kind,
        name = name, width = blob.width, height = blob.height,
        deduped = blob.deduped or false,
    }
end

-- POST /api/upload (multipart/form-data, one or more file parts).
-- Returns an array of { blob, name } or nil, error_code, status.
function _M.receive_multipart(subject)
    local ct = ngx.var.http_content_type or ""
    if not ct:lower():find("multipart/form-data", 1, true) then
        return nil, "expected_multipart", 400
    end
    local declared = tonumber(ngx.var.http_content_length)
    if declared and not _M.disk_has_room(declared) then
        return nil, "disk_full", 507
    end
    local left = _M.quota_left(subject)
    if left and declared and declared > left + 1024 * 1024 then
        return nil, "quota_exceeded", 413
    end

    local parts, serr = spool.spool_files(config.tmp_dir, pconfig.max_file_bytes, pconfig.max_files)
    if not parts then
        return nil, serr or "invalid_upload", (serr == "file_too_large") and 413 or 400
    end

    local out = {}
    for i, part in ipairs(parts) do
        local blob, code, status = _M.store(part.path, subject)
        if not blob then
            for j = i + 1, #parts do fs.unlink(parts[j].path) end
            return nil, code, status
        end
        out[#out + 1] = { blob = blob, name = part.filename }
    end
    return out
end

return _M
