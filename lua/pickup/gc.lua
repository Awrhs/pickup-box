-- Housekeeping, run on worker 0 every PICKUP_GC_INTERVAL:
--   1. release pickup codes of dead (expired/revoked) shares
--   2. forget dead shares after PICKUP_KEEP_EXPIRED
--   3. delete blobs no live share references, once PICKUP_UPLOAD_GRACE has
--      passed since they were last uploaded (so a fresh upload can still be
--      shared), together with their cached previews
--   4. drop expired tus sessions and stale temp files
local config = require "image.config"
local metadata = require "image.metadata"
local storage = require "image.storage"
local fs = require "image.fs_ffi"
local upload = require "image.upload"
local pconfig = require "pickup.config"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

local UNREFERENCED = [[
    SELECT hash, orig_ext FROM images
    WHERE uploaded_at < ?
      AND hash NOT IN (
        SELECT sf.blob_hash FROM share_files sf JOIN shares s ON s.id = sf.share_id
        WHERE s.revoked = 0 AND s.expires_at > ?)
    LIMIT 500]]

local function still_unreferenced(db, hash, now)
    local row = db:query_row([[
        SELECT 1 AS x FROM images WHERE hash = ? AND uploaded_at < ?
          AND hash NOT IN (
            SELECT sf.blob_hash FROM share_files sf JOIN shares s ON s.id = sf.share_id
            WHERE s.revoked = 0 AND s.expires_at > ?)]], hash, now - pconfig.upload_grace, now)
    return row ~= nil
end

function _M.run_once(now)
    now = now or ngx.time()
    local stats = { codes = 0, shares = 0, blobs = 0, bytes = 0, tus = 0, tmp = 0 }

    metadata.write(function(db)
        db:run("UPDATE shares SET code = NULL WHERE code IS NOT NULL AND (revoked = 1 OR expires_at <= ?)", now)
        stats.codes = db:changes()
        db:run("DELETE FROM shares WHERE expires_at <= ?", now - pconfig.keep_expired)
        stats.shares = db:changes()
    end)

    local candidates = metadata.rows(UNREFERENCED, now - pconfig.upload_grace, now)
    for _, row in ipairs(candidates) do
        local lock = upload.lock_blob(row.hash)
        if lock then
            local removed = metadata.write(function(db)
                if not still_unreferenced(db, row.hash, now) then return false end
                db:run("DELETE FROM images WHERE hash = ?", row.hash)
                return true
            end)
            if removed then
                local path = storage.orig_path(row.hash, row.orig_ext)
                stats.bytes = stats.bytes + (fs.file_size(path) or 0)
                fs.unlink(path)
                storage.purge_cache(row.hash)
                stats.blobs = stats.blobs + 1
            end
            lock:unlock()
        end
    end

    stats.tus = metadata.tus_session_expire(now) or 0

    -- Multipart temp files (mp-<epoch>-<rand>.part) live for one request;
    -- leftovers older than a day come from crashed workers.
    for name in fs.walk_dir(config.tmp_dir) do
        local born = tonumber(name:match("^mp%-(%d+)%-%x+%.part$"))
        if born and born < now - 86400 then
            fs.unlink(config.tmp_dir .. "/" .. name)
            stats.tmp = stats.tmp + 1
        end
    end

    metadata.checkpoint()
    if stats.codes + stats.shares + stats.blobs + stats.tus + stats.tmp > 0 then
        logger.info("pickup_gc", stats)
    end
    return stats
end

function _M.init()
    if ngx.worker.id() ~= 0 then return end
    local function tick(premature)
        if premature then return end
        local ok, err = pcall(_M.run_once)
        if not ok then logger.err("pickup_gc_failed", { error = tostring(err) }) end
        local ok2, terr = ngx.timer.at(pconfig.gc_interval, tick)
        if not ok2 then ngx.log(ngx.ERR, "[pickup gc] cannot schedule: ", terr) end
    end
    local ok, err = ngx.timer.at(math.min(30, pconfig.gc_interval), tick)
    if not ok then ngx.log(ngx.ERR, "[pickup gc] cannot schedule: ", err) end
end

return _M
