-- Process lifecycle hooks.
local _M = {}

-- init_by_lua (nginx master, before workers fork).
function _M.master()
    require "resty.core"
    local pconfig = require "pickup.config"
    local secret = require "pickup.secret"
    local _, source = secret.init()
    if source == "ephemeral" then
        ngx.log(ngx.WARN, "[pickup] could not persist a secret under the data directory; ",
                "share access tokens will reset on restart")
    end
    if pconfig.owner_password and #pconfig.owner_password < pconfig.min_password_len then
        error("PICKUP_PASSWORD must be at least " .. pconfig.min_password_len
              .. " characters (set PICKUP_MIN_PASSWORD_LENGTH to change)")
    end
    if not pconfig.owner_password and not pconfig.users
       and not os.getenv("IMAGE_API_KEYS") and not os.getenv("IMAGE_API_KEY_FILE") then
        ngx.log(ngx.WARN, "[pickup] no PICKUP_PASSWORD configured: nobody can upload")
    end
end

-- init_worker_by_lua.
function _M.worker()
    local config = require "image.config"
    config.ensure_dirs()
    local circuit = require "common.circuit_breaker"
    circuit.init()
    -- One breaker per output format so a broken encoder only disables itself.
    for _, fmt in ipairs({ "jpeg", "png", "webp", "gif", "avif" }) do
        circuit.register("image_" .. fmt, {
            failure_threshold = 3, timeout_seconds = 30, half_open_max_requests = 1,
        })
    end
    local vips = require "image.vips_ffi"
    if vips.available() then
        for _, fmt in ipairs({ "jpeg", "png", "webp", "gif", "avif" }) do
            local suffix = fmt == "jpeg" and ".jpg" or "." .. fmt
            if not vips.probe_encode(suffix) then
                ngx.log(ngx.WARN, "[pickup] encoder unavailable: ", fmt)
                for _ = 1, 5 do circuit.record_failure("image_" .. fmt) end
            end
        end
    end
    require("image.cache_maintenance").init()
    require("pickup.gc").init()
end

return _M
