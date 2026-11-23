local ngx = ngx
local shared = ngx.shared
local logger = require "common.logger"

local _M = {}

local circuit_dict = shared.circuit_state

-- 熔断器状态
local STATE_CLOSED = "closed"
local STATE_OPEN = "open"
local STATE_HALF_OPEN = "half_open"

local CIRCUIT_CONFIG = {
    -- 图片处理（C/libvips）熔断器：连续失败时快速降级返回原图，
    -- 避免对一个挂掉的图像处理库持续堆积请求。
    image = {
        failure_threshold = 5,
        timeout_seconds = 15,
        half_open_max_requests = 3
    }
}

local function get_state_key(service)
    return "circuit:" .. service .. ":state"
end

local function get_failure_count_key(service)
    return "circuit:" .. service .. ":failures"
end

local function get_open_time_key(service)
    return "circuit:" .. service .. ":open_time"
end

local function get_half_open_count_key(service)
    return "circuit:" .. service .. ":half_open_count"
end

-- Default profile used for dynamically-registered services (e.g. image
-- processing is tracked per output format so a missing AVIF encoder does not
-- disable all transforms).
local DEFAULT_PROFILE = {
    failure_threshold = 5,
    timeout_seconds = 15,
    half_open_max_requests = 3,
}

-- Ensure a service has a config profile without resetting existing state.
function _M.register(service, profile)
    if not CIRCUIT_CONFIG[service] then
        CIRCUIT_CONFIG[service] = profile or DEFAULT_PROFILE
        if circuit_dict then
            circuit_dict:set(get_state_key(service), STATE_CLOSED)
            circuit_dict:set(get_failure_count_key(service), 0)
        end
    end
    return CIRCUIT_CONFIG[service]
end

function _M.init()
    -- 初始化所有服务为 closed 状态
    for service, _ in pairs(CIRCUIT_CONFIG) do
        circuit_dict:set(get_state_key(service), STATE_CLOSED)
        circuit_dict:set(get_failure_count_key(service), 0)
    end
end

function _M.get_state(service)
    local state = circuit_dict:get(get_state_key(service))
    return state or STATE_CLOSED
end

local function open_circuit(service)
    circuit_dict:set(get_state_key(service), STATE_OPEN)
    circuit_dict:set(get_open_time_key(service), ngx.time())
    circuit_dict:set(get_half_open_count_key(service), 0)
    logger.warn("circuit_opened", { service = service })
end

local function close_circuit(service)
    circuit_dict:set(get_state_key(service), STATE_CLOSED)
    circuit_dict:set(get_failure_count_key(service), 0)
    logger.warn("circuit_closed", { service = service })
end

local function half_open_circuit(service)
    circuit_dict:set(get_state_key(service), STATE_HALF_OPEN)
    circuit_dict:set(get_half_open_count_key(service), 0)
    logger.warn("circuit_half_open", { service = service })
end

function _M.allow_request(service)
    local config = CIRCUIT_CONFIG[service]
    if not config then
        return true
    end

    local state = _M.get_state(service)

    if state == STATE_CLOSED then
        return true
    end

    if state == STATE_OPEN then
        local open_time = circuit_dict:get(get_open_time_key(service)) or 0
        if ngx.time() - open_time >= config.timeout_seconds then
            -- 进入半开状态
            half_open_circuit(service)
            return true
        end
        return false
    end

    -- STATE_HALF_OPEN
    local half_open_count = circuit_dict:incr(get_half_open_count_key(service), 1, 0)
    if half_open_count <= config.half_open_max_requests then
        return true
    end
    return false
end

function _M.record_success(service)
    local state = _M.get_state(service)

    if state == STATE_HALF_OPEN then
        -- 半开状态成功，关闭熔断器
        close_circuit(service)
    elseif state == STATE_CLOSED then
        -- 重置失败计数
        circuit_dict:set(get_failure_count_key(service), 0)
    end
end

function _M.record_failure(service)
    local config = CIRCUIT_CONFIG[service] or _M.register(service)
    if not config then
        return
    end

    local state = _M.get_state(service)

    if state == STATE_HALF_OPEN then
        -- 半开状态失败，重新打开熔断器
        open_circuit(service)
    elseif state == STATE_CLOSED then
        local failures = circuit_dict:incr(get_failure_count_key(service), 1, 0)
        if failures >= config.failure_threshold then
            open_circuit(service)
        end
    end
end

function _M.reset(service)
    if service then
        close_circuit(service)
    else
        for s, _ in pairs(CIRCUIT_CONFIG) do
            close_circuit(s)
        end
    end
end

return _M
