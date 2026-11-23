-- Reconcile on-disk state with the metadata table on a long interval:
--   * unlink originals whose row is soft-deleted
--   * unlink orphan files (no corresponding row, e.g. from a crash between
--     storage.write_original and metadata.insert_image)
--
-- The walk is I/O heavy and is intentionally restricted to worker 0 and run
-- infrequently (default 6h). Failures are logged and retried next interval.
local config = require "image.config"
local metadata = require "image.metadata"
local processing = require "image.processing"
local fs = require "image.fs_ffi"
local storage = require "image.storage"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

local CHECK_INTERVAL = tonumber(os.getenv("IMAGE_GC_INTERVAL")) or 6 * 3600

local PHASH_BACKFILL = tonumber(os.getenv("IMAGE_PHASH_BACKFILL")) or 20

function _M.run_once()
    local removed, bytes = metadata.gc_orphans()
    if not removed then
        logger.err("image_gc_failed", { error = tostring(bytes) })
        return
    end
    if removed > 0 then
        logger.warn("image_gc_reclaimed", { files = removed, bytes = bytes })
    end

    -- Expire tus sessions whose expiry has passed (clean up part files).
    local expired = metadata.tus_session_expire(ngx.time())
    if expired > 0 then
        logger.warn("tus_sessions_expired", { count = expired })
    end

    -- Phash backfill: compute perceptual hashes for up to N rows per run.
    if config.phash_enabled then
        local missing = metadata.images_missing_phash(PHASH_BACKFILL)
        for _, row in ipairs(missing) do
            local path = storage.orig_path(row.hash, row.orig_ext)
            if fs.exists(path) then
                local phash, perr = processing.phash_file(path)
                if phash then
                    metadata.set_phash(row.hash, phash)
                else
                    logger.warn("phash_backfill_failed",
                        { hash = row.hash, error = tostring(perr) })
                end
            end
        end
    end
end

function _M.init()
    if ngx.worker.id() ~= 0 then return end
    -- Run one sweep shortly after startup, then every CHECK_INTERVAL.
    local function run(premature)
        if premature then return end
        pcall(_M.run_once)
        local ok, err = ngx.timer.at(CHECK_INTERVAL, run)
        if not ok then
            ngx.log(ngx.ERR, "[IMAGE_GC] failed to schedule timer: ", err)
        end
    end
    local ok, err = ngx.timer.at(60, run)  -- first run 1 minute after boot
    if not ok then
        ngx.log(ngx.ERR, "[IMAGE_GC] failed to schedule initial timer: ", err)
    end
end

return _M
