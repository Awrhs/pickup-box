-- LuaJIT FFI wrapper over c/image_vips.so (the C libvips helper).
--
-- This module loads the precompiled shared object and exposes three safe
-- functions: process(), process_file() and dimensions(). All GObject/vips
-- memory handling lives in C; here we only marshal Lua strings/options to the
-- iv_options struct and always free returned buffers with iv_free().
local ffi = require "ffi"
local ngx = ngx

local _M = {}

-- Locate the compiled helper. The Dockerfile builds it to /opt/pickup-box/c/image_vips.so.
-- For local development it can be overridden via IMAGE_VIPS_LIB.
local LIB_PATH = os.getenv("IMAGE_VIPS_LIB") or "/opt/pickup-box/c/image_vips.so"

ffi.cdef[[
typedef struct {
    int    width;
    int    height;
    int    crop;
    int    quality;
    int    max_pixels;
    int    grayscale;
    int    auto_orient;
    int    flatten;
    int    preserve_iptc;
    double blur_sigma;
    const char *wm_path;
    double      wm_opacity;
    const char *wm_position;
    const char *wm_text;
    const char *wm_font_desc;
    double wm_text_color[3];
    double wm_text_scale;
    int    wm_margin;
    int    wm_font_size;
    double wm_image_scale;
} iv_options;

int iv_process_buffer(const void *in_buf, size_t in_len,
                      const char *target_suffix,
                      const iv_options *opts,
                      void **out_buf, size_t *out_len,
                      char *err, size_t errlen);

int iv_process_file(const char *in_path,
                    const char *target_suffix,
                    const iv_options *opts,
                    void **out_buf, size_t *out_len,
                    char *err, size_t errlen);

int iv_image_dimensions(const void *in_buf, size_t in_len,
                        int *out_width, int *out_height,
                        char *err, size_t errlen);

int iv_image_dimensions_file(const char *in_path,
                             int *out_width, int *out_height,
                             char *err, size_t errlen);

void iv_free(void *p);

long long iv_cache_enforce_quota(const char *dir, long long target_bytes,
                                 int *deleted, char *err, size_t errlen);
long long iv_cache_dir_size(const char *dir, char *err, size_t errlen);
int iv_probe_encode(const char *target_suffix);
int iv_set_font_path(const char *path);
int iv_phash_file(const char *path, char *out_hex, char *err, size_t errlen);
]]

local lib_ok, lib = pcall(ffi.load, LIB_PATH)
if not lib_ok then
    -- Defer the hard error until a function is actually called, so the gateway
    -- can still serve unprocessed originals if the C extension failed to build.
    ngx.log(ngx.ERR, "[VIPS_FFI] failed to load ", LIB_PATH, ": ", lib)
    lib = nil
end

local ERR_BUF_SIZE = 1024
local DEFAULT_MAX_PIXELS = 50 * 1000 * 1000  -- 50 MP

function _M.available()
    return lib ~= nil
end

-- Build a const iv_options* from a Lua table. Any cdata strings passed for
-- wm_path/wm_position must remain alive for the duration of the call; we keep
-- them in `anchors` (returned alongside the struct) to prevent GC.
function _M.build_options(opts)
    opts = opts or {}
    local o = ffi.new("iv_options")
    ffi.fill(o, ffi.sizeof(o))

    o.width        = opts.width or 0
    o.height       = opts.height or 0
    o.crop         = opts.crop and 1 or 0
    o.quality      = opts.quality or 82
    o.max_pixels   = opts.max_pixels or DEFAULT_MAX_PIXELS
    o.grayscale    = opts.grayscale and 1 or 0
    -- Auto-orient by default; mobile uploads rely on EXIF orientation.
    o.auto_orient  = (opts.auto_orient == false) and 0 or 1
    o.flatten      = opts.flatten and 1 or 0
    o.blur_sigma   = opts.blur_sigma or 0.0
    o.wm_opacity   = opts.watermark_opacity or 0.3

    local anchors = {}
    if opts.watermark_path and opts.watermark_path ~= "" then
        anchors.wm_path = ffi.new("char[?]", #opts.watermark_path + 1)
        ffi.copy(anchors.wm_path, opts.watermark_path)
        o.wm_path = anchors.wm_path
    end
    if opts.watermark_position and opts.watermark_position ~= "" then
        anchors.wm_position = ffi.new("char[?]", #opts.watermark_position + 1)
        ffi.copy(anchors.wm_position, opts.watermark_position)
        o.wm_position = anchors.wm_position
    end

    -- Text watermark
    o.wm_font_size  = opts.watermark_font_size or 0
    o.wm_text_scale = opts.watermark_text_scale or 0.0
    o.wm_margin     = opts.watermark_margin or 0
    o.wm_image_scale = opts.watermark_image_scale or 0.0
    if opts.watermark_text_color then
        o.wm_text_color[0] = tonumber(opts.watermark_text_color[1]) or 1.0
        o.wm_text_color[1] = tonumber(opts.watermark_text_color[2]) or 1.0
        o.wm_text_color[2] = tonumber(opts.watermark_text_color[3]) or 1.0
    else
        o.wm_text_color[0] = 1.0
        o.wm_text_color[1] = 1.0
        o.wm_text_color[2] = 1.0
    end
    if opts.watermark_text and opts.watermark_text ~= "" then
        anchors.wm_text = ffi.new("char[?]", #opts.watermark_text + 1)
        ffi.copy(anchors.wm_text, opts.watermark_text)
        o.wm_text = anchors.wm_text
    end
    if opts.watermark_font_desc and opts.watermark_font_desc ~= "" then
        anchors.wm_font_desc = ffi.new("char[?]", #opts.watermark_font_desc + 1)
        ffi.copy(anchors.wm_font_desc, opts.watermark_font_desc)
        o.wm_font_desc = anchors.wm_font_desc
    end

    return o, anchors
end

local function call_process(fn, a1, suffix, opts)
    if not lib then
        return nil, "image_vips C library not available (" .. LIB_PATH .. ")"
    end
    suffix = suffix or ".jpg"

    local c_opts, anchors = _M.build_options(opts)
    local out_buf = ffi.new("void*[1]")
    local out_len = ffi.new("size_t[1]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)

    local rc = fn(a1, suffix, c_opts, out_buf, out_len, errbuf, ERR_BUF_SIZE)
    if rc ~= 0 then
        return nil, "vips processing failed: " .. ffi.string(errbuf)
    end

    local ptr = out_buf[0]
    local len = tonumber(out_len[0])
    if ptr == nil or len == 0 then
        return nil, "vips returned empty output"
    end

    local result = ffi.string(ptr, len)
    lib.iv_free(ptr)
    -- anchors must stay alive until after iv_free; this reference enforces it.
    if anchors then anchors = nil end
    return result
end

-- Process an encoded image string into another encoded image string.
-- opts: { width, height, crop, quality, max_pixels, grayscale, auto_orient,
--         flatten, blur_sigma, suffix, watermark_path, watermark_opacity,
--         watermark_position }
function _M.process(data, opts)
    if not data or #data == 0 then return nil, "empty input" end
    return call_process(lib.iv_process_buffer, data, opts and opts.suffix, opts)
end

-- Process an image from a file path (avoids copying large originals through
-- the Lua heap).
function _M.process_file(path, opts)
    if not path or path == "" then return nil, "empty path" end
    return call_process(lib.iv_process_file, path, opts and opts.suffix, opts)
end

-- Low-level entry points safe to call from a worker thread. They take ONLY
-- transferable arguments (string/table), build the FFI cdata locally, and
-- return an encoded string. Do not touch the ngx API from these.
function _M._call_buffer(data, suffix, opts)
    if not data or #data == 0 then return nil, "empty input" end
    if not lib then return nil, "image_vips C library not available" end
    local c_opts, anchors = _M.build_options(opts)
    local out_buf = ffi.new("void*[1]")
    local out_len = ffi.new("size_t[1]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)
    local rc = lib.iv_process_buffer(data, #data, suffix, c_opts,
                                     out_buf, out_len, errbuf, ERR_BUF_SIZE)
    if rc ~= 0 then return nil, "vips failed: " .. ffi.string(errbuf) end
    local ptr, len = out_buf[0], tonumber(out_len[0])
    if ptr == nil or len == 0 then return nil, "empty output" end
    local result = ffi.string(ptr, len)
    lib.iv_free(ptr)
    -- Keep `anchors` alive until after iv_free so wm strings are not GC'd
    -- while C still holds references through c_opts.
    if anchors then anchors = nil end
    return result
end

function _M._call_file(path, suffix, opts)
    if not path or path == "" then return nil, "empty path" end
    if not lib then return nil, "image_vips C library not available" end
    local c_opts, anchors = _M.build_options(opts)
    local out_buf = ffi.new("void*[1]")
    local out_len = ffi.new("size_t[1]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)
    local rc = lib.iv_process_file(path, suffix, c_opts,
                                   out_buf, out_len, errbuf, ERR_BUF_SIZE)
    if rc ~= 0 then return nil, "vips failed: " .. ffi.string(errbuf) end
    local ptr, len = out_buf[0], tonumber(out_len[0])
    if ptr == nil or len == 0 then return nil, "empty output" end
    local result = ffi.string(ptr, len)
    lib.iv_free(ptr)
    if anchors then anchors = nil end
    return result
end

-- Read (width, height) from an encoded buffer. Returns nil, err on failure.
function _M.dimensions(data)
    if not lib then return nil, "image_vips C library not available" end
    if not data or #data == 0 then return nil, "empty input" end

    local w = ffi.new("int[1]")
    local h = ffi.new("int[1]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)

    local rc = lib.iv_image_dimensions(data, #data, w, h, errbuf, ERR_BUF_SIZE)
    if rc ~= 0 then
        return nil, "vips dimensions failed: " .. ffi.string(errbuf)
    end
    return tonumber(w[0]), tonumber(h[0])
end

-- Read (width, height) from a file path. Reads only the image header, so the
-- full file never has to be copied into Lua memory.
function _M.dimensions_file(path)
    if not lib then return nil, "image_vips C library not available" end
    if not path or path == "" then return nil, "empty path" end

    local w = ffi.new("int[1]")
    local h = ffi.new("int[1]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)

    local rc = lib.iv_image_dimensions_file(path, w, h, errbuf, ERR_BUF_SIZE)
    if rc ~= 0 then
        return nil, "vips dimensions_file failed: " .. ffi.string(errbuf)
    end
    return tonumber(w[0]), tonumber(h[0])
end

-- Enforce a size quota on a cache directory, deleting least-recently-modified
-- files first. Returns (total_bytes_after, deleted_count) or (nil, err).
function _M.cache_enforce_quota(dir, target_bytes)
    if not lib then return nil, "image_vips C library not available" end
    local deleted = ffi.new("int[1]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)
    local total = lib.iv_cache_enforce_quota(dir, target_bytes,
                                             deleted, errbuf, ERR_BUF_SIZE)
    if total < 0 then
        return nil, "quota enforce failed: " .. ffi.string(errbuf)
    end
    return tonumber(total), tonumber(deleted[0])
end

-- Total size in bytes of all regular files under a cache directory.
function _M.cache_dir_size(dir)
    if not lib then return nil, "image_vips C library not available" end
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)
    local total = lib.iv_cache_dir_size(dir, errbuf, ERR_BUF_SIZE)
    if total < 0 then
        return nil, "dir_size failed: " .. ffi.string(errbuf)
    end
    return tonumber(total)
end

-- Runtime probe: returns true if the C library can actually encode to the
-- given suffix (".jpg", ".webp", ".avif", ...). Used at init to pre-trip
-- circuit breakers for missing encoders.
function _M.probe_encode(suffix)
    if not lib then return false end
    return lib.iv_probe_encode(suffix or ".jpg") == 1
end

-- Register a font file with system fontconfig at runtime.
-- Returns true on success, nil+err on failure. Must be called after
-- vips init (i.e. during worker init, not at module load).
function _M.set_font_path(path)
    if not lib then return nil, "image_vips C library not available" end
    if not path or path == "" then return true end
    local rc = lib.iv_set_font_path(path)
    if rc ~= 0 then return nil, "iv_set_font_path failed" end
    return true
end

-- pHash: perceptual hash of an image file. Returns 16-char hex string.
-- Worker-safe entry point (no ngx API touches).
function _M._phash_file(path)
    if not lib then return nil, "image_vips C library not available" end
    if not path or path == "" then return nil, "empty path" end
    local out_hex = ffi.new("char[17]")
    local errbuf = ffi.new("char[?]", ERR_BUF_SIZE)
    local rc = lib.iv_phash_file(path, out_hex, errbuf, ERR_BUF_SIZE)
    if rc ~= 0 then return nil, "phash failed: " .. ffi.string(errbuf) end
    return ffi.string(out_hex, 16)
end

return _M
