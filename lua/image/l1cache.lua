-- Level-1 in-memory cache for small image derivatives, backed by the
-- `image_l1` shared dict. This sits in front of the on-disk derivative
-- cache so that hot thumbnails are served without any file I/O.
--
-- Entries are keyed by the same deterministic cache_key used for the disk
-- cache. We only cache derivatives smaller than a threshold (large images
-- would thrash shared memory); the value is the raw encoded bytes.
local ngx = ngx

local _M = {}

-- Default cap per entry: 256 KiB. Larger derivatives skip L1 and rely on disk.
local MAX_ENTRY_BYTES = tonumber(os.getenv("IMAGE_L1_MAX_BYTES")) or (256 * 1024)

-- TTL for L1 entries. Derivatives are content-addressed and immutable, but a
-- shortish TTL bounds memory if many one-off transforms are requested.
local TTL_SECONDS = 3600

local dict = ngx.shared.image_l1

-- True if the L1 shared dict was configured in nginx.conf.
function _M.available()
    return dict ~= nil
end

-- Retrieve cached bytes for a key, or nil. The caller already knows the
-- expected mime from the transform params, so we only store the bytes.
function _M.get(key)
    if not dict then return nil end
    return dict:get(key)
end

-- Cache bytes for a key. Silently skips oversized values or LRU evictions.
function _M.set(key, data)
    if not dict or not data then return false end
    if #data > MAX_ENTRY_BYTES then return false end
    -- safe_set avoids forcibly evicting valid entries; on failure just skip.
    local ok, err = dict:safe_set(key, data, TTL_SECONDS)
    if not ok and err ~= "no memory" then
        ngx.log(ngx.WARN, "[L1CACHE] set failed: ", err)
    end
    return ok
end

function _M.delete(key)
    if not dict then return end
    dict:delete(key)
end

function _M.capacity()
    if not dict then return 0 end
    return dict:capacity()
end

function _M.free_space()
    if not dict then return 0 end
    return dict:free_space()
end

return _M
