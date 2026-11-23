-- Content-addressed on-disk storage for original images and a derivative
-- cache. All writes are atomic (temp file + rename) via the FFI libc helper.
-- This is the default storage backend; see storage.lua for the factory.
local config = require "image.config"
local fs = require "image.fs_ffi"
local ngx = ngx

local _M = {}
_M.backend_name = "local"

-- Shard a hash into ab/cd so each directory stays small.
local function shard(hash)
    return hash:sub(1, 2) .. "/" .. hash:sub(3, 4)
end

-- Absolute path to an original, given hash and canonical ext.
function _M.orig_path(hash, ext)
    return config.orig_dir .. "/" .. shard(hash) .. "/" .. hash .. "." .. ext
end

-- Absolute path to a cached derivative.
function _M.cache_path(hash, cache_key, ext)
    return config.cache_dir .. "/" .. shard(hash) .. "/"
        .. hash .. "_" .. cache_key .. "." .. ext
end

-- Ensure parent directory for a full file path exists.
local function ensure_parent(path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent then return fs.mkdir_p(parent) end
    return true
end

-- Write an original if not already present (content-addressed dedup).
-- Returns (path, existed) on success, or nil, err.
function _M.write_original(hash, ext, data)
    local final = _M.orig_path(hash, ext)
    if fs.exists(final) then return final, true end
    local ok, err = ensure_parent(final)
    if not ok then return nil, err end
    local tmp = config.tmp_dir .. "/" .. hash .. "." .. ext
        .. ".tmp." .. ngx.worker.pid()
    ok, err = fs.write_file_atomic(final, data, tmp)
    if not ok then return nil, err end
    return final, false
end

-- Local path for an original when it exists on disk, else nil. On this
-- backend the local copy IS the original, so there is nothing to fetch.
function _M.ensure_local_orig(hash, ext)
    local path = _M.orig_path(hash, ext)
    if fs.exists(path) then return path end
    return nil, "not found"
end

-- Publish a freshly uploaded temp file into content-addressed storage:
-- atomic rename (idempotent under concurrent dedup uploads — the second
-- rename overwrites the identical file, harmless). When the target already
-- exists the temp file is unlinked and (path, true) is returned.
function _M.place_orig(tmp, hash, ext)
    local final = _M.orig_path(hash, ext)
    if fs.exists(final) then
        fs.unlink(tmp)
        return final, true
    end
    local parent = final:match("^(.*)/[^/]+$")
    if parent then fs.mkdir_p(parent) end
    local ok, rerr = fs.rename(tmp, final)
    if not ok then return nil, rerr end
    return final, false
end

-- Write a derivative into the cache.
function _M.write_cache(path, data)
    local ok, err = ensure_parent(path)
    if not ok then return nil, err end
    local tmp = path .. ".tmp." .. ngx.worker.pid()
    return fs.write_file_atomic(path, data, tmp)
end

function _M.read(path)       return fs.read_file(path) end
function _M.exists(path)     return fs.exists(path) end
function _M.size(path)       return fs.file_size(path) end
function _M.delete_orig(hash, ext)
    return fs.unlink(_M.orig_path(hash, ext))
end

-- Purge all cached derivatives for a hash. We enumerate the shard directory
-- and unlink files matching the hash prefix.
function _M.purge_cache(hash)
    local dir = config.cache_dir .. "/" .. shard(hash)
    if not fs.exists(dir) then return true end
    local prefix = hash .. "_"
    for name in fs.walk_dir(dir) do
        if name:sub(1, #prefix) == prefix then
            fs.unlink(dir .. "/" .. name)
        end
    end
    return true
end

-- Translate an on-disk absolute path to the internal X-Accel-Redirect URI that
-- nginx serves via sendfile (see location /__image_file/ in nginx.conf).
function _M.to_internal_uri(abs_path)
    local prefix = config.data_dir
    local rel = abs_path:sub(#prefix + 1)
    if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
    return config.file_location .. rel
end

return _M
