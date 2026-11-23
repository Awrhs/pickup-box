-- Pretty HTML/JSON error responses. Content negotiation: if the Accept header
-- includes "text/html", return a small standalone HTML page; otherwise return
-- application/json. Image responses (when the caller is an <img> tag) get a
-- 1x1 SVG placeholder from transform.serve_error_placeholder.
local ngx = ngx
local _M = {}

local PAGES = {
    [400] = { title = "Bad Request",       desc = "请求参数有问题" },
    [401] = { title = "Unauthorized",      desc = "需要有效的 API Key" },
    [403] = { title = "Forbidden",         desc = "没有访问权限" },
    [404] = { title = "Not Found",         desc = "图片不存在或已删除" },
    [405] = { title = "Method Not Allowed", desc = "请求方法不支持" },
    [410] = { title = "Gone",              desc = "图片已被删除" },
    [413] = { title = "Payload Too Large", desc = "文件超过大小上限" },
    [429] = { title = "Too Many Requests", desc = "请求过于频繁，请稍后再试" },
    [500] = { title = "Internal Error",    desc = "服务暂时不可用" },
    [503] = { title = "Service Unavailable", desc = "服务暂时不可用" },
}

local function wants_html()
    local accept = ngx.var.http_accept or ""
    return accept:find("text/html", 1, true) ~= nil
end

function _M.respond(status, message, opts)
    opts = opts or {}
    local info = PAGES[status] or { title = "Error", desc = message or "" }
    ngx.status = status
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    if opts.retry_after then
        ngx.header["Retry-After"] = tostring(opts.retry_after)
    end

    if wants_html() then
        ngx.header.content_type = "text/html; charset=utf-8"
        local csp = "default-src 'none'; style-src 'unsafe-inline'; form-action 'none'"
        ngx.header["Content-Security-Policy"] = csp
        ngx.say(([[<!doctype html><meta charset="utf-8">
<title>%d %s</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>body{font-family:system-ui;max-width:520px;margin:80px auto;padding:0 16px;color:#222}
h1{font-size:1.4rem;margin-bottom:.4rem}p{color:#666}
small{display:block;margin-top:2rem;color:#999}</style>
<h1>%d %s</h1><p>%s</p><small>%s</small>]]):format(
            status, info.title, status, info.title,
            message or info.desc,
            os.date("%Y-%m-%d %H:%M:%S", ngx.time())))
    else
        ngx.header.content_type = "application/json"
        local cjson = require "cjson.safe"
        ngx.say(cjson.encode({
            error = info.title,
            status = status,
            message = message or info.desc,
            trace_id = ngx.ctx and ngx.ctx.trace_id,
        }))
    end
    ngx.exit(status)
end

return _M
