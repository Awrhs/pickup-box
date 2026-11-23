-- Server secret used to sign recipient access tokens and to salt anonymised
-- client identifiers.
--
-- Resolution order (done once in init_by_lua, i.e. in the nginx master
-- before workers fork, so every worker inherits the same value):
--   1. PICKUP_SECRET (>= 32 chars)
--   2. <data dir>/.secret, created with 32 random bytes on first start
--   3. an ephemeral random value (tokens then reset on every restart)
local _M = {}

local value

local function data_dir()
    return os.getenv("IMAGE_DATA_DIR") or "/data/images"
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if s then s = s:gsub("%s+$", "") end
    if s and #s >= 32 then return s end
    return nil
end

function _M.init()
    local env = os.getenv("PICKUP_SECRET")
    if env and env ~= "" then
        if #env < 32 then
            error("PICKUP_SECRET must be at least 32 characters (or leave it unset to auto-generate)")
        end
        value = env
        return value, "env"
    end
    local path = data_dir() .. "/.secret"
    local existing = read_file(path)
    if existing then
        value = existing
        return value, "file"
    end
    local fresh = require("common.rand").hex(32)
    os.execute("mkdir -p '" .. data_dir():gsub("'", "") .. "' 2>/dev/null")
    local f = io.open(path, "wb")
    if f then
        f:write(fresh, "\n")
        f:close()
        os.execute("chmod 600 '" .. path:gsub("'", "") .. "' 2>/dev/null")
        value = fresh
        return value, "generated"
    end
    value = fresh
    return value, "ephemeral"
end

function _M.get()
    if not value then
        -- Not initialised in this VM (e.g. unit tests): use a random value.
        value = require("common.rand").hex(32)
    end
    return value
end

return _M
