-- Server-rendered HTML pages. The pickup flow (code entry, pickup page,
-- downloads) works without JavaScript; only sending files needs JS.
local pconfig = require "pickup.config"
local shares = require "pickup.shares"
local guard = require "pickup.guard"
local files = require "pickup.files"
local ngx = ngx

local _M = {}

local function esc(s)
    if s == nil then return "" end
    return (tostring(s):gsub('[&<>"\']', {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end
_M.esc = esc

function _M.human_size(n)
    n = tonumber(n) or 0
    if n < 1024 then return n .. " B" end
    local units = { "KB", "MB", "GB", "TB" }
    local v = n / 1024
    for i = 1, #units do
        if v < 1024 or i == #units then
            return (v < 10 and string.format("%.1f", v) or string.format("%.0f", v)) .. " " .. units[i]
        end
        v = v / 1024
    end
end

function _M.human_duration(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then return d .. " 天" .. (h > 0 and (" " .. h .. " 小时") or "") end
    if h > 0 then return h .. " 小时" .. (m > 0 and (" " .. m .. " 分钟") or "") end
    if m > 0 then return m .. " 分钟" end
    return "不到 1 分钟"
end

local CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; "
    .. "media-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"

local function send(status, html)
    ngx.status = status
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["Content-Security-Policy"] = CSP
    ngx.header["X-Frame-Options"] = "DENY"
    ngx.header["Referrer-Policy"] = "no-referrer"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    if ngx.req.get_method() ~= "HEAD" then ngx.print(html) end
    return ngx.exit(status)
end

local function layout(title, body, opts)
    opts = opts or {}
    local head_extra = opts.head or ""
    local scripts = ""
    for _, s in ipairs(opts.scripts or {}) do
        scripts = scripts .. '<script src="' .. s .. '" defer></script>'
    end
    return table.concat({
        '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">',
        '<meta name="referrer" content="no-referrer">',
        '<meta name="robots" content="noindex,nofollow">',
        '<title>', esc(title), '</title>',
        '<link rel="stylesheet" href="/static/app.css?v=2">', head_extra, scripts,
        '</head><body><header class="top"><a class="brand" href="/">', esc(pconfig.site_name),
        '</a></header><main>', body,
        '</main><footer class="foot">由 pickup-box 提供 · 文件到期后自动删除</footer></body></html>',
    })
end

local function message_page(status, title, text)
    return send(status, layout(title,
        '<section class="card center"><h1>' .. esc(title) .. '</h1><p>' .. esc(text)
        .. '</p><p><a class="btn" href="/">返回首页</a></p></section>'))
end
_M.message_page = message_page

-- ------------------------------------------------------------- home --

function _M.index(err_msg)
    local choices = {}
    for _, s in ipairs(pconfig.expiry_choices) do choices[#choices + 1] = tostring(s) end
    local err_html = err_msg and ('<p class="error" role="alert">' .. esc(err_msg) .. '</p>') or ""
    local body = table.concat({
        '<section class="card" id="pickup"><h2>取件</h2>',
        '<form class="code-form" action="/c" method="get">',
        '<input name="code" inputmode="numeric" pattern="[0-9]*" autocomplete="one-time-code" ',
        'maxlength="', pconfig.code_length, '" placeholder="输入 ', pconfig.code_length,
        ' 位取件码" aria-label="取件码" required>',
        '<button class="btn primary" type="submit">取件</button></form>', err_html, '</section>',

        '<section class="card" id="send" data-max-file="', pconfig.max_file_bytes,
        '" data-max-files="', pconfig.max_files, '" data-expiry-default="', pconfig.default_expiry,
        '" data-expiry-choices="', table.concat(choices, ","), '">',
        '<h2>发送文件</h2>',
        '<noscript><p class="muted">发送文件需要启用 JavaScript（取件不需要）。</p></noscript>',
        '<form id="login" class="stack" hidden>',
        '<input id="password" type="password" autocomplete="current-password" placeholder="上传密码" required>',
        '<button class="btn primary" type="submit">登录</button>',
        '<p class="error" id="login-error" role="alert" hidden></p></form>',
        '<div id="composer" hidden>',
        '<label class="picker btn primary">选择照片或文件<input id="files" type="file" multiple></label>',
        '<ul id="queue" class="queue"></ul>',
        '<div class="opts"><label>有效期 <select id="expiry"></select></label>',
        '<label>可打开次数 <select id="visits"><option value="0">不限</option>',
        '<option value="1">1 次</option><option value="3">3 次</option><option value="10">10 次</option>',
        '</select></label><label class="grow">备注 <input id="title" maxlength="60" placeholder="可选"></label></div>',
        '<button id="start" class="btn primary wide" disabled>开始发送</button>',
        '<p class="error" id="send-error" role="alert" hidden></p>',
        '<p class="muted small"><span id="usage"></span> <a href="/me">我的分享</a> · ',
        '<a href="#" id="logout">退出登录</a></p></div>',
        '<div id="result" hidden></div>',
        '</section>',
    })
    return send(err_msg and 404 or 200, layout(pconfig.site_name, body, { scripts = { "/static/common.js?v=1", "/static/app.js?v=2" } }))
end

-- GET /c?code=123456 and /c/123456
function _M.code_lookup(code)
    code = (code or ngx.var.arg_code or ""):gsub("%s+", "")
    if guard.blocked("code") then
        ngx.header["Retry-After"] = tostring(guard.retry_after("code"))
        return message_page(429, "尝试次数太多", "取件码输错太多次了，请一小时后再试。")
    end
    if not code:match("^%d+$") or #code ~= pconfig.code_length then
        guard.fail("code")
        return _M.index("取件码是 " .. pconfig.code_length .. " 位数字，请检查后重试。")
    end
    local share = shares.get_by_code(code)
    if not share then
        guard.fail("code")
        return _M.index("取件码不正确，或者分享已经过期。")
    end
    return ngx.redirect("/p/" .. share.slug, 302)
end

-- --------------------------------------------------------- pickup page --

local BOT_UA = { "bot", "crawler", "spider", "facebookexternalhit", "slurp", "whatsapp",
                 "telegram", "slack", "discord", "skypeuripreview", "iframely", "embedly" }

local function is_bot()
    local ua = (ngx.var.http_user_agent or ""):lower()
    if ua == "" then return true end
    for _, p in ipairs(BOT_UA) do
        if ua:find(p, 1, true) then return true end
    end
    return false
end

local KIND_ICON = { video = "🎬", audio = "🎵", other = "📄", image = "🖼️" }

local function file_tile(share, f, t)
    local base = "/p/" .. share.slug .. "/f/" .. f.seq
    local q = "?t=" .. ngx.escape_uri(t)
    local name = esc(f.name)
    local size = _M.human_size(f.size_bytes)
    local dl = '<a class="dl" href="' .. base .. q .. '&amp;dl=1">下载</a>'
    if f.kind == "image" then
        return '<li class="tile"><a class="thumb" href="' .. base .. '/thumb' .. q .. '&amp;s=l">'
            .. '<img src="' .. base .. '/thumb' .. q .. '&amp;s=s" loading="lazy" alt="' .. name .. '"></a>'
            .. '<div class="cap"><span class="name">' .. name .. '</span><span class="size">'
            .. size .. '</span>' .. dl .. '</div></li>'
    elseif f.kind == "video" then
        return '<li class="tile wide"><video controls playsinline preload="metadata" src="'
            .. base .. q .. '"></video><div class="cap"><span class="name">' .. name
            .. '</span><span class="size">' .. size .. '</span>' .. dl .. '</div></li>'
    elseif f.kind == "audio" then
        return '<li class="tile wide"><audio controls preload="none" src="' .. base .. q
            .. '"></audio><div class="cap"><span class="name">' .. name .. '</span><span class="size">'
            .. size .. '</span>' .. dl .. '</div></li>'
    end
    return '<li class="tile wide file"><span class="icon">' .. KIND_ICON.other .. '</span>'
        .. '<div class="cap"><span class="name">' .. name .. '</span><span class="size">'
        .. size .. '</span>' .. dl .. '</div></li>'
end

function _M.pickup(slug)
    local share = shares.get_by_slug(slug)
    if not share then
        return message_page(404, "找不到这个分享", "链接可能输错了，或者分享已被清理。")
    end
    local st = shares.state(share)
    if st == "revoked" then
        return message_page(410, "分享已撤回", "发送者已经撤回了这个分享。")
    elseif st == "expired" then
        return message_page(410, "分享已过期", "这个分享已经过期，文件已不可下载。请联系发送者重新发送。")
    end

    local count = tonumber(share.file_count) or 0
    if is_bot() then
        -- Link previews (chat apps) must not consume visits.
        return send(200, layout(pconfig.site_name,
            '<section class="card center"><h1>有人给你发送了 ' .. count .. ' 个文件</h1>'
            .. '<p>在浏览器中打开链接即可查看和下载。</p></section>',
            { head = '<meta property="og:title" content="' .. esc(pconfig.site_name .. "：" .. count .. " 个文件") .. '">' }))
    end

    local t = ngx.var.arg_t
    if not shares.verify_token(share, t) then
        if ngx.req.get_method() == "HEAD" then return send(200, "") end
        if not shares.consume_visit(share) then
            return message_page(410, "访问次数已用完", "这个分享设置了可打开次数，现在已经用完了。")
        end
        -- Redirect to a tokenised URL so reloading does not count again.
        return ngx.redirect("/p/" .. slug .. "?t=" .. ngx.escape_uri(shares.mint_token(share)), 302)
    end

    local list = shares.files(share.id)
    local tiles = {}
    for _, f in ipairs(list) do tiles[#tiles + 1] = file_tile(share, f, t) end

    local now = ngx.time()
    local meta = { count .. " 个文件", _M.human_size(share.total_bytes),
                   _M.human_duration(share.expires_at - now) .. "后过期" }
    local maxv = tonumber(share.max_visits) or 0
    if maxv > 0 then
        meta[#meta + 1] = "还可打开 " .. math.max(0, maxv - share.visit_count) .. " 次"
    end
    local title = share.title ~= "" and share.title or (count .. " 个文件")
    local ua = ngx.var.http_user_agent or ""
    local wechat = ua:find("MicroMessenger", 1, true)
        and '<p class="notice">微信里可能无法直接下载：请点右上角「···」选择「在浏览器打开」。图片可以长按保存。</p>'
        or ""
    local body = table.concat({
        '<section class="pickup"><h1>', esc(title), '</h1>',
        '<p class="meta">', esc(table.concat(meta, " · ")), '</p>', wechat,
        '<p><a class="btn primary" href="/p/', share.slug, '/zip?t=', ngx.escape_uri(t),
        '">全部下载（zip）</a></p>',
        '<ul class="grid">', table.concat(tiles), '</ul></section>',
    })
    return send(200, layout(title .. " - " .. pconfig.site_name, body))
end

-- Sub-resources of a share: /p/<slug>/{zip,qr.svg,f/<seq>[/thumb]}
function _M.pickup_dispatch()
    local uri = ngx.var.uri
    local slug, rest = uri:match("^/p/([%w]+)(.*)$")
    if not slug then return message_page(404, "找不到这个分享", "链接不完整。") end
    if rest == "" or rest == "/" then return _M.pickup(slug) end

    local share = shares.get_by_slug(slug)
    if not share then return require("image.errors").respond(404, "share not found") end

    if rest == "/qr.svg" then return files.serve_qr(share) end

    files.authorize(share)
    if rest == "/zip" then
        return files.serve_zip(share, shares.files(share.id))
    end
    local seq, sub = rest:match("^/f/(%d+)(.*)$")
    if not seq then return require("image.errors").respond(404, "not found") end
    local f = shares.file(share.id, seq)
    if not f then return require("image.errors").respond(404, "file not found") end
    if sub == "" then return files.serve_file(share, f) end
    if sub == "/thumb" then return files.serve_thumb(share, f) end
    return require("image.errors").respond(404, "not found")
end

-- --------------------------------------------------------------- /me --

function _M.me()
    local body = '<section class="card"><h2>我的分享</h2>'
        .. '<form id="login" class="stack" hidden><input id="password" type="password" '
        .. 'autocomplete="current-password" placeholder="上传密码" required>'
        .. '<button class="btn primary" type="submit">登录</button>'
        .. '<p class="error" id="login-error" hidden></p></form>'
        .. '<div id="mine" hidden><p class="muted small"><a href="/">← 发送新文件</a> · '
        .. '<a href="#" id="logout">退出登录</a></p><ul id="share-list" class="share-list"></ul>'
        .. '<p class="muted" id="empty" hidden>还没有分享。</p></div>'
        .. '<noscript><p class="muted">此页面需要启用 JavaScript。</p></noscript></section>'
    return send(200, layout("我的分享 - " .. pconfig.site_name, body, { scripts = { "/static/common.js?v=1", "/static/me.js?v=1" } }))
end

return _M
