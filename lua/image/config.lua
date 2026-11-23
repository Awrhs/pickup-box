-- Image hosting configuration (all via env vars, per project convention)
local ngx = ngx
local _M = {}

local function bool(v, default)
    if v == nil then return default end
    return v == "1" or v == "true" or v == "TRUE" or v == "yes"
end

local function num(v, default)
    local n = tonumber(v)
    if not n then return default end
    return n
end

-- Storage root; mount this as a persistent volume
_M.data_dir        = os.getenv("IMAGE_DATA_DIR") or "/data/images"
_M.orig_dir        = _M.data_dir .. "/orig"
_M.cache_dir       = _M.data_dir .. "/cache"
_M.tmp_dir         = _M.data_dir .. "/tmp"
_M.db_path         = os.getenv("IMAGE_DB_PATH") or (_M.data_dir .. "/image.db")

-- Upload/auth.
--
-- Two ways to provision API keys:
--
--   1) IMAGE_API_KEYS (comma separated) for simple "key-only" deployments.
--      Each entry is either a bare secret or "<name>:<secret>[:<role>]"
--      (role = "upload" or "admin"; default "upload"). Bare secrets are
--      given the name "default" and the upload role.
--
--   2) IMAGE_API_KEY_FILE — path to a newline-separated file of the same
--      "<name>:<secret>[:<role>]" format. The file is re-read if its mtime
--      changes, so rotating keys does not require a reload.
--
-- In both cases the gateway stores only sha256(secret) in memory — plaintext
-- secrets never touch logs, disk, or the database. `uploaded_by` is recorded
-- as the same key hash, which lets owners enumerate/delete only their own
-- images without a key ever being persisted in plaintext.
_M.api_keys          = {}  -- [key_name] = { hash=..., role="upload"|"admin" }
_M.api_key_by_hash   = {}  -- [hash]     = { name=..., role=... }

local function register_key(name, secret, role, quota, expires)
    if not name or name == "" or not secret or secret == "" then return end
    local resty_sha = require "resty.sha256"
    local h = resty_sha:new(); h:update(secret)
    local hex = require "resty.string".to_hex(h:final())
    role = (role == "admin" or role == "upload") and role or "upload"
    local q = tonumber(quota)
    local exp = tonumber(expires)
    _M.api_keys[name] = { hash = hex, role = role, quota = q, expires = exp }
    _M.api_key_by_hash[hex] = { name = name, role = role, quota = q, expires = exp }
end

-- Parse a single key entry. Accepts:
--   "<bare-secret>"
--   "<name>:<secret>"
--   "<name>:<secret>:<role>"
--   "<name>:<secret>:<role>:<quota>"
--   "<name>:<secret>:<role>:<quota>:<expires_unix>"
-- role/quota may be empty; an empty role defaults to "upload".
local function parse_entry(entry)
    local parts = {}
    for field in (entry .. ":"):gmatch("([^:]*):") do
        parts[#parts + 1] = field
    end
    if #parts == 1 then
        return "default", entry, "upload", nil, nil
    end
    if #parts > 5 or parts[1] == "" or parts[2] == "" then
        return nil  -- malformed; caller skips it
    end
    local name, secret, role, quota, expires = parts[1], parts[2], parts[3], parts[4], parts[5]
    if not role or role == "" then role = "upload" end
    if quota == "" or (quota and not quota:match("^%d+$")) then quota = nil end
    if expires == "" or (expires and not expires:match("^%d+$")) then expires = nil end
    return name, secret, role, quota, expires
end
_M._parse_key_entry = parse_entry  -- exposed for unit tests

do
    local raw = os.getenv("IMAGE_API_KEYS") or ""
    for tok in string.gmatch(raw, "[^,]+") do
        local entry = tok:gsub("^%s+", ""):gsub("%s+$", "")
        if #entry > 0 then
            local name, secret, role, quota, expires = parse_entry(entry)
            if name and secret then
                register_key(name, secret, role, quota, expires)
            end
        end
    end
end

-- (Re-)load keys from IMAGE_API_KEY_FILE, throttled to once per
-- KEY_FILE_REFRESH_SECONDS so we don't re-parse on every request. The file is
-- expected to be small (a few dozen keys), so a short refresh interval is
-- cheap without needing fragile stat() ABI structures for mtime.
local KEY_FILE_REFRESH_SECONDS = 10
function _M.reload_key_file(force)
    if not _M.api_key_file then return end
    if not force and ngx and ngx.time then
        local now = ngx.time()
        if _M.api_key_file_loaded_at
           and (now - _M.api_key_file_loaded_at) < KEY_FILE_REFRESH_SECONDS then
            return
        end
        _M.api_key_file_loaded_at = now
    end
    local fs = require "image.fs_ffi"
    local size = fs.file_size(_M.api_key_file)
    if not size then return end
    -- Also skip if the file has not changed size since the last successful
    -- load; rotating keys almost always changes size as well.
    if not force and size == _M.api_key_file_size then return end
    _M.api_key_file_size = size

    local data = fs.read_file(_M.api_key_file)
    if not data then return end

    -- Wipe file-provisioned keys (env-provided keys are re-added below if they
    -- share a name). We track which names came from the file.
    if _M._key_file_names then
        for n in pairs(_M._key_file_names) do
            local entry = _M.api_keys[n]
            if entry then
                _M.api_key_by_hash[entry.hash] = nil
                _M.api_keys[n] = nil
            end
        end
    end
    _M._key_file_names = {}

    for line in string.gmatch(data, "[^\r\n]+") do
        local entry = line:gsub("^%s+", ""):gsub("%s+$", "")
        if entry ~= "" and entry:sub(1, 1) ~= "#" then
            local name, secret, role, quota, expires = parse_entry(entry)
            if name and secret then
                register_key(name, secret, role, quota, expires)
                _M._key_file_names[name] = true
            end
        end
    end
end

_M.api_key_file       = os.getenv("IMAGE_API_KEY_FILE")
_M.api_key_file_size  = 0

-- Per-user monthly quota, in bytes. 0 disables. Can be overridden per key via
-- the key file using the optional 4th field: name:secret:role:quota_bytes.
_M.default_quota_bytes = num(os.getenv("IMAGE_DEFAULT_QUOTA_BYTES"), 0)
_M.quota_window_days   = num(os.getenv("IMAGE_QUOTA_WINDOW_DAYS"), 30)

_M.max_upload_bytes   = num(os.getenv("IMAGE_MAX_UPLOAD_BYTES"), 20 * 1024 * 1024)  -- 20 MiB
_M.max_pixels         = num(os.getenv("IMAGE_MAX_PIXELS"), 40 * 1000 * 1000)        -- 40 MP guard
_M.allow_original_format = bool(os.getenv("IMAGE_ALLOW_ORIGINAL_FORMAT"), true)     -- allow fmt=original
_M.allowed_formats    = { jpeg = true, jpg = true, png = true, webp = true, gif = true, avif = true }
_M.output_formats     = { jpeg = true, png = true, webp = true, avif = true, gif = true }

-- Caching
_M.cache_seconds      = num(os.getenv("IMAGE_CACHE_SECONDS"), 31536000)  -- 1 year immutable
_M.enable_processing  = bool(os.getenv("IMAGE_ENABLE_PROCESSING"), true)
_M.watermark_path     = os.getenv("IMAGE_WATERMARK_PATH")  -- optional path to watermark PNG
_M.watermark_opacity  = num(os.getenv("IMAGE_WATERMARK_OPACITY"), 0.3)    -- 0..1
_M.watermark_position = os.getenv("IMAGE_WATERMARK_POSITION") or "southeast"

-- Upload UI
_M.upload_page_title  = os.getenv("IMAGE_UPLOAD_TITLE") or "pickup-box"

-- Internal location (nginx) used to stream files via sendfile
_M.file_location      = "/__image_file/"

-- Storage backend: only "local" (on-disk content-addressed store).
_M.storage_backend    = os.getenv("IMAGE_STORAGE_BACKEND") or "local"

-- pHash perceptual hash (P3). 0 disables; threshold is Hamming distance.
_M.phash_enabled  = bool(os.getenv("IMAGE_PHASH_ENABLED"), true)
_M.phash_reject   = bool(os.getenv("IMAGE_PHASH_REJECT"), false)
_M.phash_threshold = num(os.getenv("IMAGE_PHASH_THRESHOLD"), 10)
_M.phash_backfill = num(os.getenv("IMAGE_PHASH_BACKFILL"), 20)

-- Text watermark (P2): renders text via vips_text/Pango. The font file is
-- mounted at runtime (not built into the image); no font path = disabled.
_M.text_font_path        = os.getenv("IMAGE_TEXT_FONT_PATH")
_M.watermark_font_desc   = os.getenv("IMAGE_TEXT_FONT_DESC") or "sans"
-- Configurable watermark defaults; any value <= 0 defers to the C built-in.
_M.watermark_text_scale  = num(os.getenv("IMAGE_WATERMARK_TEXT_SCALE"), 0.04)
_M.watermark_margin      = num(os.getenv("IMAGE_WATERMARK_MARGIN"), 16)
_M.watermark_image_scale = num(os.getenv("IMAGE_WATERMARK_IMAGE_SCALE"), 0.2)

-- MIME by extension
_M.mime = {
    jpeg = "image/jpeg", jpg = "image/jpeg",
    png = "image/png",
    gif = "image/gif",
    webp = "image/webp",
    avif = "image/avif",
}

-- format as written into a vips suffix
_M.vips_suffix = {
    jpeg = ".jpg", jpg = ".jpg",
    png = ".png",
    gif = ".gif",
    webp = ".webp",
    avif = ".avif",
}

-- Common widths to pre-generate after upload (srcset-friendly). Empty disables.
-- Parsed from IMAGE_PREGENERATE_SIZES as a comma-separated list of pixel widths.
_M.pregenerate_widths = {}
do
    local raw = os.getenv("IMAGE_PREGENERATE_SIZES") or "320,640,1024,1920"
    for tok in string.gmatch(raw, "%d+") do
        local w = tonumber(tok)
        if w and w >= 16 and w <= 10000 then
            _M.pregenerate_widths[#_M.pregenerate_widths + 1] = w
        end
    end
end
-- Format used for pre-generated derivatives. Defaults to webp for the
-- best size/quality; set to "original" to keep the source format.
_M.pregenerate_format = os.getenv("IMAGE_PREGENERATE_FORMAT") or "webp"
_M.pregenerate_quality = num(os.getenv("IMAGE_PREGENERATE_QUALITY"), 82)

function _M.ensure_dirs()
    local fs = require "image.fs_ffi"
    fs.mkdir_p(_M.data_dir)
    fs.mkdir_p(_M.orig_dir)
    fs.mkdir_p(_M.cache_dir)
    fs.mkdir_p(_M.tmp_dir)
end

return _M
