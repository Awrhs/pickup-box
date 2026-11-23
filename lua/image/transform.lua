-- Image transformation orchestration:
--   L1 (shared dict) -> disk cache -> single-flight -> C/libvips (offloaded)
-- -> persist to both caches -> stream (sendfile from disk, or direct bytes
-- from memory).
--
-- Correctness/robustness features:
--   * Per-output-format circuit breaker so a broken AVIF encoder does not
--     disable all transforms.
--   * Format fallback chain: if the requested encode (e.g. avif) fails,
--     try webp then jpeg before returning an error.
--   * Vary: Accept on negotiated responses so caches do not serve WebP/AVIF
--     to clients that cannot decode them.
--   * ETag/If-None-Match 304 for cacheable derivatives.
--   * HEAD short-circuits (never runs processing).
--   * CPU work runs through image.processing (semaphore gate + thread offload).
local config = require "image.config"
local storage = require "image.storage"
local util = require "image.util"
local processing = require "image.processing"
local l1 = require "image.l1cache"
local security = require "image.security"
local metrics = require "common.metrics"
local logger = require "common.logger"
local circuit = require "common.circuit_breaker"
local resty_lock = require "resty.lock"
local ngx = ngx

local _M = {}

-- Ordered fallback when an encoder fails (e.g. AVIF support missing in the
-- build). Each entry: { fmt, ext, mime, suffix }.
local FALLBACK_CHAIN = {
    avif = { { "webp", "webp", config.mime.webp, ".webp" },
             { "jpeg", "jpg",  config.mime.jpeg, ".jpg" } },
    webp = { { "jpeg", "jpg", config.mime.jpeg, ".jpg" } },
}

-- Circuit-breaker service name, scoped per output format.
local function cb_service(fmt)
    return "image_" .. (fmt or "orig")
end

local function format_info(fmt)
    if fmt == "jpeg" then return "jpg", config.mime.jpeg, ".jpg" end
    if fmt == "jpg"  then return "jpg", config.mime.jpeg, ".jpg" end
    if fmt == "png"  then return "png", config.mime.png, ".png" end
    if fmt == "webp" then return "webp", config.mime.webp, ".webp" end
    if fmt == "gif"  then return "gif", config.mime.gif, ".gif" end
    if fmt == "avif" then return "avif", config.mime.avif, ".avif" end
    return nil
end

-- Pick the best output format from the Accept header if the client did not
-- explicitly request one.
local function negotiate_format(accept)
    if not accept then return nil end
    accept = accept:lower()
    if accept:find("image/avif", 1, true) then return "avif" end
    if accept:find("image/webp", 1, true) then return "webp" end
    return nil
end

-- Deterministic cache key for a transform request. Implemented in
-- util.cache_key (shared with pregenerator) so the serving path and the
-- pre-generation path can never drift apart.
local cache_key = util.cache_key

local function set_cache_headers(immutable, vary_accept)
    if ngx.ctx.pb_private_cache then
        -- Share previews: never let shared caches keep them past revocation.
        ngx.header["Cache-Control"] = "private, max-age=3600"
    elseif immutable then
        ngx.header["Cache-Control"] = "public, max-age=" .. config.cache_seconds .. ", immutable"
    else
        ngx.header["Cache-Control"] = "public, max-age=300"
    end
    if vary_accept then
        ngx.header["Vary"] = "Accept"
    end
end

-- Detect whether the on-disk original is an animated GIF/WebP by reading
-- just the head. For GIF the NETSCAPE2.0 application extension typically
-- appears in the first few hundred bytes, so we read 2 KiB to be safe.
-- Caches the result on `meta` so repeated requests don't re-read.
local fs = require "image.fs_ffi"
local function is_animated_original(hash, meta)
    if meta._animated_checked then return meta._is_animated end
    meta._animated_checked = true
    if meta.orig_ext ~= "gif" and meta.orig_ext ~= "webp" then
        return false
    end
    local head = fs.read_head(storage.orig_path(hash, meta.orig_ext), 2048)
    if head then
        meta._is_animated = util.is_animated(head, meta.orig_ext)
    end
    return meta._is_animated
end

-- If the request carries ?download=1, force a Content-Disposition so the
-- browser saves the file instead of opening it inline. The filename is derived
-- from the image hash so it is stable and ASCII-safe.
local function maybe_download_header(hash, ext)
    local args = ngx.req.get_uri_args()
    if args.download == "1" or args.dl == "1" then
        ngx.header["Content-Disposition"] =
            'attachment; filename="' .. hash .. '.' .. ext .. '"'
    end
end

-- Emit a tiny SVG placeholder with a 500 status. Used when processing fails
-- and the original is also unreadable: returning an image (rather than
-- text/plain) makes the failure render cleanly inside an <img> tag. The
-- response is `Cache-Control: no-store` so retries re-hit the server.
local function serve_error_placeholder()
    ngx.status = 500
    ngx.header["Content-Type"] = "image/svg+xml; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Image-Error"] = "processing_failed"
    if ngx.req.get_method() ~= "HEAD" then
        ngx.print('<?xml version="1.0" encoding="UTF-8"?>'
            .. '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="150" '
            .. 'viewBox="0 0 200 150"><rect width="100%" height="100%" fill="#f3f4f6"/>'
            .. '<text x="50%" y="50%" text-anchor="middle" '
            .. 'font-family="system-ui" font-size="13" fill="#9ca3af">'
            .. 'image unavailable</text></svg>')
    end
    ngx.exit(500)
end

-- ETag is a quoted, URL-safe form of the cache key. The key is already
-- composed of [w0-9a-f._] (no quotes/backslashes/non-ASCII), so wrapping it
-- verbatim produces a valid HTTP quoted-string per RFC 7232. We mark it as a
-- weak validator (W/) because the same logical transform can be produced by
-- different libvips versions/micro-versions and produce different bytes —
-- this avoids over-aggressive caching when the C library is upgraded.
local function quoted_etag(key)
    return 'W/"' .. key .. '"'
end

-- Compare If-None-Match, accepting either weak or strong form of our ETag.
local function etag_matches(inm, etag)
    if not inm or inm == "" then return false end
    -- Browsers send back exactly what we set, including W/.
    if inm == etag then return true end
    -- Strip weak prefix on either side and compare.
    local function strip(s) return s:gsub("^W/", "") end
    return strip(inm) == strip(etag)
end

-- Return 304 if the client already has this representation.
local function check_not_modified(etag)
    local inm = ngx.var.http_if_none_match
    if etag_matches(inm, etag) then
        ngx.status = 304
        -- 304 must carry the same ETag as the full response.
        ngx.header["ETag"] = etag
        ngx.exit(304)
        return true
    end
    return false
end

-- Record how many bytes we expect to send so log_by_lua can meter them even
-- though the body is streamed by an internal X-Accel-Redirect (where
-- $body_bytes_sent from the original location is not reliable).
local function record_bytes(n)
    if n and n > 0 then ngx.ctx.image_bytes = n end
end

-- Stream a file path back through nginx (sendfile, Range support) via an
-- internal redirect to the internal blob location. Headers set here survive
-- the redirect. (X-Accel-Redirect is only honoured for proxied upstream
-- responses, not for content_by_lua, hence ngx.exec.)
local function stream_file(path, mime, immutable, vary_accept, etag, size)
    ngx.header["Content-Type"] = mime
    set_cache_headers(immutable, vary_accept)
    if etag then ngx.header["ETag"] = etag end
    record_bytes(size or storage.size(path) or 0)
    return ngx.exec(storage.to_internal_uri(path))
end

-- Serve encoded bytes straight from memory.
local function serve_bytes(data, mime, immutable, vary_accept, etag)
    ngx.header["Content-Type"] = mime
    set_cache_headers(immutable, vary_accept)
    if etag then ngx.header["ETag"] = etag end
    ngx.header["Content-Length"] = #data
    record_bytes(#data)
    if ngx.req.get_method() ~= "HEAD" then
        ngx.print(data)
    end
    ngx.exit(ngx.OK)
end

-- Run the C/libvips pipeline for (source data/path) and try fallback formats
-- on encoder failure. Returns (data, ext, mime, fmt_used) or (nil, err).
local function render(source, is_file, opts_for_fmt)
    local function attempt(arg, suffix, p_opts)
        p_opts.suffix = suffix
        if is_file then
            return processing.process_file(arg, p_opts)
        end
        return processing.process(arg, p_opts)
    end

    local fmt = opts_for_fmt.fmt
    local try = { fmt }
    local fb = FALLBACK_CHAIN[fmt]
    if fb then
        for _, f in ipairs(fb) do try[#try + 1] = f[1] end
    end

    local last_err
    for i, candidate in ipairs(try) do
        local ext, mime, suffix = format_info(candidate)
        if ext then
            local p_opts = {}
            for k, v in pairs(opts_for_fmt) do p_opts[k] = v end
            p_opts.fmt = candidate
            p_opts.suffix = suffix

            local svc = cb_service(candidate)
            if not circuit.allow_request(svc) then
                last_err = "circuit open for " .. candidate
            else
                local out, err = attempt(source, suffix, p_opts)
                if out then
                    circuit.record_success(svc)
                    return out, ext, mime, candidate
                end
                -- Record failure so the breaker can trip, then try the next
                -- format in the fallback chain.
                circuit.record_failure(svc)
                last_err = err
                logger.warn("encode_failed_fallback",
                    { fmt = candidate, fallback = tostring(i < #try), error = err })
            end
        end
    end
    return nil, last_err or "all encoders failed"
end

-- Build the vips opts table from request params.
local function build_opts(params, out_fmt)
    local wm_path = params.watermark and config.watermark_path or nil
    local wm_text_color
    if params.watermark_text_color_hex then
        local hex = params.watermark_text_color_hex
        wm_text_color = {
            (tonumber(hex:sub(1,2), 16) or 255) / 255,
            (tonumber(hex:sub(3,4), 16) or 255) / 255,
            (tonumber(hex:sub(5,6), 16) or 255) / 255,
        }
    end
    return {
        width = params.width,
        height = params.height,
        crop = params.crop,
        quality = params.quality,
        max_pixels = config.max_pixels,
        grayscale = params.grayscale,
        blur_sigma = params.blur,
        auto_orient = true,
        watermark_path = wm_path,
        watermark_opacity = config.watermark_opacity,
        watermark_position = config.watermark_position,
        watermark_text = params.watermark_text,
        watermark_font_size = params.watermark_font_size,
        watermark_text_color = wm_text_color,
        watermark_font_desc = config.watermark_font_desc,
        watermark_text_scale = config.watermark_text_scale,
        watermark_margin = config.watermark_margin,
        watermark_image_scale = config.watermark_image_scale,
        fmt = out_fmt,
    }
end

-- `params_override` (optional) replaces the query-string transform params;
-- pickup-box uses it to allow only fixed preview sizes.
function _M.serve(hash, requested_ext, params_override)
    local metadata = require "image.metadata"
    -- trace_id is initialized at the server rewrite phase; just make sure.
    if not ngx.ctx.trace_id then
        require "common.logger".init_request()
    end
    local meta = metadata.get_image(hash)
    if not meta then util.not_found("image not found") end

    -- Resolve the original on local disk (stat only).
    local orig_path = storage.ensure_local_orig(hash, meta.orig_ext)
    if not orig_path then util.not_found("image not found") end

    if not config.enable_processing then
        local cd = security.original_content_disposition(hash, meta.orig_ext)
        if cd then ngx.header["Content-Disposition"] = cd end
        stream_file(orig_path, meta.mime, false, false, nil)
        return
    end

    -- For animated GIF/WebP we do not attempt to re-encode every frame (the
    -- C pipeline is single-image). If a transform was requested, we still
    -- serve the original bytes rather than producing a silently de-animated
    -- thumbnail, and signal the fact with X-Image-Animated: 1.

    local params, perr = params_override, nil
    if not params then params, perr = util.parse_transform_args() end
    if not params then util.bad_request(perr) end

    -- HEAD must never trigger expensive processing. Serve from cache only,
    -- otherwise reply with headers and length of the original.
    local is_head = ngx.req.get_method() == "HEAD"

    local out_fmt = params.format
    local negotiated = false
    if not out_fmt and not params.noop then
        out_fmt = negotiate_format(ngx.var.http_accept)
        if out_fmt then negotiated = true end
    end

    -- Animated images: our single-image vips pipeline cannot re-encode all
    -- frames, and doing so silently de-animates the result. When a transform
    -- or format conversion is requested on an animated source, pass the
    -- original through unchanged and signal it via X-Image-Animated so
    -- clients (and caches) know.
    if not params.noop and is_animated_original(hash, meta) then
        if storage.exists(orig_path) then
            ngx.header["X-Image-Animated"] = "1"
            local cd = security.original_content_disposition(hash, meta.orig_ext)
            if cd then ngx.header["Content-Disposition"] = cd end
            stream_file(orig_path, meta.mime, false, negotiated, nil)
            return
        end
    end

    if params.noop and not out_fmt then
        if not storage.exists(orig_path) then util.not_found() end
        local cd = security.original_content_disposition(hash, meta.orig_ext)
        if cd then ngx.header["Content-Disposition"] = cd end
        stream_file(orig_path, meta.mime, false, negotiated, nil)
        return
    end

    -- No explicit or negotiated format: re-encode in the original's format.
    -- (Leaving out_fmt nil gave render() an empty candidate list, so every
    -- resize without fmt= or a webp/avif Accept header failed.)
    if not out_fmt then
        out_fmt = util.canonical_format(meta.orig_ext)
        if not out_fmt then util.bad_request("unsupported source format") end
    end
    local out_ext, out_mime = format_info(out_fmt)
    if not out_ext then util.bad_request("unsupported format") end

    local ckey = cache_key(params, out_fmt)
    local l1key = hash .. ":" .. ckey
    local cached_path = storage.cache_path(hash, ckey, out_ext)
    local etag = quoted_etag(ckey)

    -- 1) L1 memory cache hit.
    local l1_hit = l1.get(l1key)
    if l1_hit then
        metrics.incr_image_cache_hit()
        if check_not_modified(etag) then return end
        serve_bytes(l1_hit, out_mime, true, negotiated, etag)
        return
    end

    -- 2) Disk cache hit.
    if storage.exists(cached_path) then
        metrics.incr_image_cache_hit()
        local disk_data = storage.read(cached_path)
        if disk_data then l1.set(l1key, disk_data) end
        if check_not_modified(etag) then return end
        stream_file(cached_path, out_mime, true, negotiated, etag)
        return
    end

    -- For HEAD with a cache miss, do not process. Report the original's
    -- existence and let a subsequent GET build the derivative.
    if is_head then
        ngx.header["Content-Type"] = out_mime
        set_cache_headers(false, negotiated)
        ngx.exit(ngx.OK)
        return
    end

    metrics.incr_image_cache_miss()

    -- 3) Single-flight lock.
    local lock = resty_lock:new("image_locks", { timeout = 10, exptime = 30 })
    local elapsed, lock_err = lock:lock(l1key)
    if not elapsed then
        logger.warn("transform_lock_failed", { key = l1key, error = lock_err })
    end

    local l1_after = l1.get(l1key)
    if l1_after then
        if elapsed then lock:unlock() end
        metrics.incr_image_cache_hit()
        serve_bytes(l1_after, out_mime, true, negotiated, etag)
        return
    end
    if storage.exists(cached_path) then
        if elapsed then lock:unlock() end
        metrics.incr_image_cache_hit()
        stream_file(cached_path, out_mime, true, negotiated, etag)
        return
    end

    -- 4) Circuit breaker at the aggregate level: if the primary format's
    -- breaker is open AND no fallback is viable, serve the original.
    local svc = cb_service(out_fmt)
    if not circuit.allow_request(svc) and not FALLBACK_CHAIN[out_fmt] then
        if elapsed then lock:unlock() end
        metrics.incr_image_error()
        logger.warn("image_circuit_open", { hash = hash, fmt = out_fmt })
        local orig = storage.orig_path(hash, meta.orig_ext)
        if storage.exists(orig) then stream_file(orig, meta.mime, false, negotiated) end
        serve_error_placeholder()
    end

    -- 5) Read original from disk and render (offloaded). We keep the original
    -- out of the Lua heap when possible by passing the path; libvips reads it
    -- sequentially in the worker thread.
    if not storage.exists(orig_path) then
        if elapsed then lock:unlock() end
        util.not_found()
    end

    local p_opts = build_opts(params, out_fmt)
    local start = ngx.now()
    local processed, used_ext, used_mime, used_fmt
        = render(orig_path, true, p_opts)
    metrics.observe_image_process(ngx.now() - start)

    if not processed then
        if elapsed then lock:unlock() end
        metrics.incr_image_error()
        logger.err("vips_failed", { error = used_ext, hash = hash })
        -- Last resort: serve original bytes if they exist; otherwise return a
        -- tiny SVG placeholder with status 500 so <img> tags don't get
        -- text/plain garbage.
        if storage.exists(orig_path) then
            stream_file(orig_path, meta.mime, false, negotiated)
        end
        serve_error_placeholder()
    end

    -- If the fallback changed the format, recompute path/key/etag for the
    -- actual output format so caching is consistent.
    if used_fmt and used_fmt ~= out_fmt then
        out_ext = used_ext
        out_mime = used_mime
        ckey = cache_key(params, used_fmt)
        l1key = hash .. ":" .. ckey
        cached_path = storage.cache_path(hash, ckey, out_ext)
        etag = quoted_etag(ckey)
        negotiated = true -- format may differ per Accept; always Vary
    end
    -- Note: circuit success/failure for both primary and fallback formats is
    -- recorded inside render(). Do NOT record again here.
    metrics.incr_image_processed()

    -- 6) Populate caches and serve.
    l1.set(l1key, processed)
    local ok, write_err = storage.write_cache(cached_path, processed)
    if not ok then
        logger.warn("cache_write_failed", { error = write_err })
        if elapsed then lock:unlock() end
        serve_bytes(processed, out_mime, false, negotiated, etag)
        return
    end

    if elapsed then lock:unlock() end
    if not params_override then maybe_download_header(hash, out_ext) end
    stream_file(cached_path, out_mime, true, negotiated, etag)
end

return _M
