-- Concurrency gate and event-loop offload for the CPU-heavy libvips call.
--
-- libvips processing is pure CPU and would otherwise block the nginx event
-- loop for tens to hundreds of milliseconds per large image. This module:
--
--   1. Limits the number of in-flight vips operations per worker with a
--      semaphore (IMAGE_MAX_CONCURRENCY), so concurrent big images cannot
--      exhaust memory across all connections.
--   2. Runs the C call on a dedicated OS thread via ngx.run_worker_thread
--      (lua-resty-core) when available, so the event loop is not blocked.
--      It falls back to an in-line call when offloading is unavailable.
--
-- The offloaded functions live on the vips_ffi module and take only
-- transferable arguments (string + plain table); they build FFI cdata
-- internally and must not touch the ngx API.
local vips = require "image.vips_ffi"
local logger = require "common.logger"
local ngx = ngx
local tonumber = tonumber

local _M = {}

-- Max simultaneous vips operations per worker. Each op is single-threaded in
-- C (vips_concurrency=1), so a good default is around the number of CPU cores,
-- capped to bound per-worker memory.
local MAX_CONCURRENCY = tonumber(os.getenv("IMAGE_MAX_CONCURRENCY")) or 2
-- How long (ms) to wait for a concurrency slot before giving up.
local ACQUIRE_TIMEOUT = tonumber(os.getenv("IMAGE_ACQUIRE_TIMEOUT_MS")) or 30000

local semaphore = require "ngx.semaphore"
local slot = semaphore.new()
for _ = 1, MAX_CONCURRENCY do slot:post(1) end

-- ngx.run_worker_thread is available on recent OpenResty with lua-resty-core.
-- It requires a named thread pool declared via `thread_pool` in nginx.conf (main context).
-- When absent we run inline (blocking, but correct).
local has_thread_api = type(ngx.run_worker_thread) == "function"
local thread_pool = os.getenv("IMAGE_THREAD_POOL") or "default"

-- Module-qualified names of the offloaded entry points (resolved by name in
-- the thread runtime).
local VMOD = "image.vips_ffi"
local BUFFER_FN = "_call_buffer"
local FILE_FN   = "_call_file"
local PHASH_FN  = "_phash_file"

local function acquire()
    local ok, err = slot:wait(ACQUIRE_TIMEOUT)
    if not ok then
        return nil, "processing concurrency timeout: " .. tostring(err)
    end
    return true
end

local function release()
    slot:post(1)
end

-- Run fn on a worker thread if available, else inline. `fn_name` must be a
-- module-level function; all args must be transferable (string/number/table).
local function run_offloaded(fn_name, ...)
    if has_thread_api then
        -- ngx.run_worker_thread returns (thread_ok, ret1, ret2, ...); the
        -- outer pcall adds its own status in front.
        local called, thread_ok, result, err = pcall(ngx.run_worker_thread,
                                                     thread_pool, VMOD, fn_name, ...)
        if called and thread_ok then
            return result, err
        end
        -- Environmental failure (e.g. unknown thread pool, queue full) or an
        -- error inside the thread -> inline fallback.
        logger.warn("worker_thread_fallback",
                    { error = tostring(called and result or thread_ok) })
    end
    return vips[fn_name](...)
end

-- Process an encoded image string. `opts` is the same table accepted by
-- vips.process() (see vips_ffi.lua). Returns (data) or (nil, err).
function _M.process(data, opts)
    if not vips.available() then
        return nil, "image_vips C library not available"
    end

    local got, gerr = acquire()
    if not got then return nil, gerr end

    local suffix = (opts and opts.suffix) or ".jpg"
    local result, err = run_offloaded(BUFFER_FN, data, suffix, opts or {})
    release()
    return result, err
end

-- Process an image from a file path (used for disk-backed originals so we do
-- not copy multi-megabyte buffers through the Lua heap).
function _M.process_file(path, opts)
    if not vips.available() then
        return nil, "image_vips C library not available"
    end

    local got, gerr = acquire()
    if not got then return nil, gerr end

    local suffix = (opts and opts.suffix) or ".jpg"
    local result, err = run_offloaded(FILE_FN, path, suffix, opts or {})
    release()
    return result, err
end

function _M.concurrency()
    return MAX_CONCURRENCY
end

-- SHA-256 + CRC-32 + size of a file in one streaming pass, computed on the
-- OS thread pool so multi-GB uploads never stall the event loop. Not gated by
-- the libvips concurrency semaphore (it is pure I/O + hashing). Falls back to
-- an in-process Lua implementation when the C helper is unavailable.
function _M.digest_file(path)
    if vips.available() then
        local res, err = run_offloaded("_digest_file", path)
        if res then return res end
        logger.warn("digest_offload_failed", { error = tostring(err) })
    end
    return require("common.digest").file(path)
end

-- Compute perceptual hash of a file. Returns 16-char hex string or nil, err.
function _M.phash_file(path)
    if not vips.available() then
        return nil, "image_vips C library not available"
    end
    local got, gerr = acquire()
    if not got then return nil, gerr end
    local result, err = run_offloaded(PHASH_FN, path)
    release()
    return result, err
end

return _M
