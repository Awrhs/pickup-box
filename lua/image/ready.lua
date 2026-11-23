-- Readiness probe for the image hosting subsystem.
-- Returns { ok = bool, checks = { ... } } where each check has a name and
-- either ok=true or ok=false with a reason string. Cheap enough to call from
-- /readyz on every poll.
local config = require "image.config"
local vips = require "image.vips_ffi"
local ngx = ngx

local _M = {}

-- Best-effort disk free check via statvfs(2). We only declare not-ready if
-- the data directory has less than MIN_FREE_BYTES available.
local MIN_FREE_BYTES = 50 * 1024 * 1024  -- 50 MiB

local function check_disk()
    local fs = require "image.fs_ffi"
    for _, dir in ipairs({ config.orig_dir, config.cache_dir, config.tmp_dir }) do
        if not fs.exists(dir) then
            return { name = "disk", ok = false, reason = "missing " .. dir }
        end
    end
    local _, free = fs.disk_stats(config.data_dir)
    if free and free < MIN_FREE_BYTES then
        return { name = "disk", ok = false,
                 reason = "low disk: " .. tostring(free) .. " bytes free" }
    end
    return { name = "disk", ok = true }
end

local function check_metadata()
    local metadata = require "image.metadata"
    local ok, err = pcall(metadata.init)
    if not ok or not metadata.ready() then
        return { name = "metadata", ok = false, reason = tostring(err or "db unavailable") }
    end
    return { name = "metadata", ok = true }
end

local function check_vips()
    if not vips.available() then
        return { name = "vips", ok = false, reason = "image_vips.so not loaded" }
    end
    return { name = "vips", ok = true }
end

function _M.checks()
    return {
        check_vips(),
        check_metadata(),
        check_disk(),
    }
end

function _M.ready()
    local all = _M.checks()
    for _, c in ipairs(all) do
        if not c.ok then return false, all end
    end
    return true, all
end

return _M
