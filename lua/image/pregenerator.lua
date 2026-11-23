-- Asynchronously pre-generate common derivative sizes (srcset) for a freshly
-- uploaded image. Runs in an ngx.timer so the upload response is not blocked.
--
-- Failures are logged but never surface to the client; on-demand generation in
-- transform.lua remains the source of truth if any pre-gen step fails.
--
-- Cache keys come from the shared util.cache_key so a pre-generated file is
-- always found by the live path (byte-identical keys by construction).
local config = require "image.config"
local storage = require "image.storage"
local util = require "image.util"
local vips = require "image.vips_ffi"
local processing = require "image.processing"
local l1 = require "image.l1cache"
local logger = require "common.logger"
local circuit = require "common.circuit_breaker"
local ngx = ngx

local _M = {}

-- Generate one derivative from a file and persist it to disk cache + L1.
local function generate_from_file(orig_path, hash, width, format, quality)
    local ext = (format == "jpeg") and "jpg" or format
    local suffix = config.vips_suffix[format] or ("." .. ext)
    -- Canonical pre-gen params: proportional width, no crop/gray/blur/wm.
    local ckey = util.cache_key({
        width = width, height = 0, crop = false, quality = quality,
        watermark = false, grayscale = false, blur = 0,
    }, format)
    local key = hash .. ":" .. ckey
    local path = storage.cache_path(hash, ckey, ext)

    -- Skip if already generated (e.g. dedup upload of an existing image).
    if storage.exists(path) then return end

    local svc = "image_" .. format
    if not circuit.allow_request(svc) then return end

    local out, err = processing.process_file(orig_path, {
        suffix = suffix,
        width = width,
        height = 0,
        crop = false,
        quality = quality,
        max_pixels = config.max_pixels,
        auto_orient = true,
    })
    if not out then
        circuit.record_failure(svc)
        logger.err("pregenerate_failed", { hash = hash, width = width, error = err })
        return
    end
    circuit.record_success(svc)

    local ok, werr = storage.write_cache(path, out)
    if not ok then
        logger.warn("pregenerate_cache_write_failed", { hash = hash, error = werr })
    end
    l1.set(key, out)
end

-- Timer callback reading from an on-disk original (preferred; no Lua heap).
local function run_file(premature, orig_path, hash, format)
    if premature then return end
    if not vips.available() then return end

    local quality = config.pregenerate_quality
    for _, w in ipairs(config.pregenerate_widths) do
        local ok, perr = pcall(generate_from_file, orig_path, hash, w, format, quality)
        if not ok then
            logger.err("pregenerate_pcall_failed", { hash = hash, width = w, error = perr })
        end
    end
end

-- Resolve the configured pre-generation format, honoring "original".
local function resolve_format(orig_ext)
    local fmt = config.pregenerate_format
    if fmt == "original" then
        if orig_ext == "jpg" then return "jpeg" end
        if config.output_formats[orig_ext] then return orig_ext end
        return "webp"
    end
    return fmt
end

-- Schedule pre-generation for an uploaded image, reading the original from
-- disk. This is the preferred entry point (post-streaming upload).
function _M.schedule_file(orig_path, hash, orig_ext)
    if #config.pregenerate_widths == 0 then return end
    if not vips.available() then return end
    local format = resolve_format(orig_ext)
    local ok, err = ngx.timer.at(0, run_file, orig_path, hash, format)
    if not ok then
        logger.err("pregenerate_timer_failed", { hash = hash, error = err })
    end
end

-- Backwards-compatible in-memory variant (kept for callers that already hold
-- the bytes). Spools to a temp file, runs the same offloaded path, and unlinks
-- the temp file when done.
function _M.schedule(data, hash, orig_ext)
    if #config.pregenerate_widths == 0 then return end
    if not vips.available() then return end
    local format = resolve_format(orig_ext)
    local ext = (orig_ext == "jpg") and "jpeg" or orig_ext
    local suffix = config.vips_suffix[ext]
        or (orig_ext:match("^%.") and orig_ext or ("." .. orig_ext))

    local tmp = config.tmp_dir .. "/pregen-" .. ngx.worker.pid() .. "-"
        .. ngx.time() .. "-" .. hash .. suffix
    local fs = require "image.fs_ffi"
    local ok, werr = fs.write_file_atomic(tmp, data, tmp .. ".t")
    if not ok then
        logger.warn("pregenerate_spool_failed", { error = werr })
        return
    end

    -- Wrap run_file so the temp spool is unlinked after generation completes.
    local function cleanup_run(premature, path, h, fmt)
        run_file(premature, path, h, fmt)
        pcall(fs.unlink, path)
    end
    local t_ok, terr = ngx.timer.at(0, cleanup_run, tmp, hash, format)
    if not t_ok then
        pcall(fs.unlink, tmp)
        logger.err("pregenerate_timer_failed", { hash = hash, error = terr })
    end
end

return _M
