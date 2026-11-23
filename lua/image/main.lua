-- Image hosting entry points. Wired via content_by_lua_block in nginx.conf:
--   POST /upload        -> handle_upload   (API key required)
--   GET  /i/<hash>      -> serve_image    (public, signed/optional)
--   DELETE /i/<hash>    -> delete_image   (API key required, owner only)
--   GET  /upload        -> upload_page    (simple HTML form)
--   GET  /gallery       -> gallery        (API key required)
local ngx = ngx
local string = string

local config = require "image.config"
local apikey = require "image.apikey"
local upload = require "image.upload"
local transform = require "image.transform"
local metadata = require "image.metadata"
local storage = require "image.storage"
local util = require "image.util"
local logger = require "common.logger"
local download_guard = require "image.download_guard"

local _M = {}

-- One-time setup of directories and metadata store. Safe to call repeatedly.
local initialized = false
function _M.init()
    if initialized then return end
    config.ensure_dirs()
    metadata.init()
    -- Load file-provisioned API keys once at startup; afterwards they are
    -- refreshed on a 10s throttle in apikey.authenticate().
    config.reload_key_file(true)
    initialized = true
end

local function extract_hash(uri)
    -- Accept /i/<hash>, /i/<hash>.<ext>
    local hash = string.match(uri, "^/i/([0-9a-fA-F]+)")
            or string.match(uri, "^/i/([0-9a-fA-F]+)%.%w+$")
    if not hash then return nil end
    return string.lower(hash)
end

-- /s/<slug> — short link; 302 to the canonical /i/<hash>.<ext>.
function _M.short_redirect()
    _M.init()
    local slug = ngx.var.uri:match("^/s/([0-9A-Za-z]+)$")
    if not slug then util.not_found("invalid slug") end
    local hash = metadata.get_slug(slug)
    if not hash then util.not_found("unknown slug") end
    local meta = metadata.get_image(hash)
    if not meta then util.not_found() end
    local args = ngx.var.is_args or ""
    local qs   = ngx.var.query_string or ""
    return ngx.redirect("/i/" .. hash .. "." .. meta.orig_ext
                        .. (args ~= "" and (args .. qs) or ""), 302)
end

-- GET /i/<hash>[.<ext>]
function _M.serve_image()
    _M.init()
    local hash = extract_hash(ngx.var.uri)
    if not hash then util.not_found("invalid hash") end
    transform.serve(hash, nil)
end

-- POST /upload
function _M.handle_upload()
    _M.init()
    local subject = apikey.require()
    upload.handle(subject)
end

-- DELETE /i/<hash>
-- Admins may delete any image; uploaders may delete only their own.
function _M.delete_image()
    _M.init()
    local subject = apikey.require()
    local hash = extract_hash(ngx.var.uri)
    if not hash then util.not_found("invalid hash") end

    local meta = metadata.get_image(hash)
    if not meta then util.not_found("image not found") end

    if subject.role ~= "admin" and meta.uploaded_by ~= subject.hash then
        util.forbidden("not the owner of this image")
    end

    -- Admins can delete regardless of owner; uploaders only their own.
    metadata.soft_delete(hash, subject.role == "admin" and nil or subject.hash)
    -- Best-effort original removal; derivative cache is left to expire.
    storage.delete_orig(hash, meta.orig_ext)

    ngx.status = 204
    ngx.exit(204)
end

-- GET /upload — minimal browser upload form. The API key can be supplied via
-- ?api_key=... for quick personal use, or via Authorization header.
function _M.upload_page()
    ngx.header.content_type = "text/html; charset=utf-8"
    local t = require "image.i18n".bind(ngx.var.http_accept_language)
    local title = config.upload_page_title
    ngx.say([[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>]] .. title .. [[</title>
<style>
 :root{color-scheme:light dark}
 body{font-family:system-ui,sans-serif;max-width:680px;margin:40px auto;padding:0 16px;color:#222}
 @media (prefers-color-scheme:dark){body{background:#111;color:#ddd}.drop{border-color:#444;color:#aaa}.drop.over{background:#1e293b}}
 h1{font-size:1.4rem}
 .drop{border:2px dashed #bbb;border-radius:12px;padding:32px;text-align:center;color:#666;cursor:pointer}
 .drop.over{border-color:#3b82f6;color:#3b82f6;background:#eff6ff}
 @media (prefers-color-scheme:dark){.drop.over{background:#1e3a8a33}}
 input[type=file]{margin:12px 0}
 #out{margin-top:24px;font-family:ui-monospace,Menlo,monospace;font-size:13px;white-space:pre-wrap;word-break:break-all}
 .row{margin:8px 0}
 .row label{display:inline-block;width:90px;color:#555}
 .row button{cursor:pointer}
 .key{width:280px}
 .progress{height:6px;background:#e5e7eb;border-radius:3px;overflow:hidden;margin-top:8px;display:none}
 .progress > div{height:100%%;background:#3b82f6;width:0;transition:width .2s}
 .copy{cursor:pointer;color:#2563eb;border:none;background:none;font-size:12px;margin-left:8px}
 .item{margin:12px 0;padding:8px;border:1px solid #eee;border-radius:6px}
</style></head><body>
<h1>]] .. title .. [[</h1>
<div class="drop" id="drop">]] .. (t.drop_hint or "Drag & drop an image here, or click to choose") .. [[</div>
<input type="file" id="file" accept="image/*">
<div class="row"><label>]] .. (t.api_key or "API Key") .. [[:</label><input class="key" id="key" type="password" placeholder="API Key" autocomplete="off">
<div class="progress" id="prog"><div></div></div></div>
<div class="row"><button id="go">]] .. (t.upload_btn or "Upload") .. [[</button></div>
<div id="out"></div>
<script>
const $=(id)=>document.getElementById(id);
const drop=$('drop'), file=$('file'), prog=$('prog'), bar=prog.firstElementChild, out=$('out');
drop.onclick=()=>file.click();
['dragenter','dragover'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.add('over')}));
['dragleave','drop'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.remove('over')}));
drop.addEventListener('drop',e=>{ if(e.dataTransfer.files[0]) { file.files=e.dataTransfer.files; upload(); }});
document.addEventListener('paste',e=>{
  const it=e.clipboardData.items;
  for(const i of it){ if(i.type.startsWith('image/')){
    file.files=e.clipboardData.files; upload(); break;
  }}
});
function copyBtn(text){
  const b=document.createElement('button'); b.className='copy'; b.type='button';
  b.textContent='copy'; b.onclick=()=>{navigator.clipboard.writeText(text);b.textContent='✓';setTimeout(()=>b.textContent='copy',1500);};
  return b;
}
function render(j){
  const lines=[
    ['URL',j.url],['Markdown',j.markdown],['HTML',j.html]
  ];
  out.innerHTML='';
  for(const [label,val] of lines){
    const div=document.createElement('div'); div.className='item';
    div.textContent=label+': '+val;
    div.appendChild(copyBtn(val));
    out.appendChild(div);
  }
}
async function uploadOne(f,key){
  prog.style.display='block'; bar.style.width='0%';
  const fd=new FormData(); fd.append('file',f);
  return new Promise((resolve,reject)=>{
    const x=new XMLHttpRequest();
    x.open('POST','/upload');
    x.setRequestHeader('Authorization','Bearer '+key);
    x.upload.onprogress=e=>{ if(e.lengthComputable) bar.style.width=(e.loaded/e.total*100)+'%'; };
    x.onload=()=>{ try{resolve([x.status,JSON.parse(x.responseText)])}catch(_){resolve([x.status,{}])} };
    x.onerror=()=>reject(new Error('network error'));
    x.send(fd);
  });
}
async function upload(){
  const key=$('key').value.trim(); if(!key){alert('API Key required');return;}
  const files=[...file.files]; if(!files.length) return;
  out.innerHTML='';
  for(const f of files){
    const line=document.createElement('div'); line.className='item';
    line.textContent='上传中: '+f.name; out.appendChild(line);
    try{
      const [status,j]=await uploadOne(f,key);
      if(status!==201){ line.textContent='失败 '+f.name+': '+(j.error||status); continue; }
      line.innerHTML='';
      const link=document.createElement('a'); link.href=j.url; link.target='_blank';
      link.textContent=f.name+' ('+Math.round((j.size||0)/1024)+' KiB)';
      line.appendChild(link); line.appendChild(copyBtn(j.markdown));
    }catch(e){ line.textContent='错误: '+e; }
  }
  prog.style.display='none';
}
$('go').onclick=upload;
file.setAttribute('multiple','multiple');
</script>
</body></html>]])
    ngx.exit(200)
end

-- GET /gallery — JSON list of recent uploads (admin key required).
function _M.gallery()
    _M.init()
    apikey.require_admin()
    local args = ngx.req.get_uri_args()
    local limit = util.parse_int(args.limit, 50, 1, 200)
    local rows = metadata.recent(limit)
    local base = ngx.var.scheme .. "://" .. ngx.var.host
    for _, r in ipairs(rows) do
        r.url = base .. "/i/" .. r.hash .. "." .. r.orig_ext
    end
    ngx.header.content_type = "application/json"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode({ images = rows }))
    ngx.exit(200)
end

-- GET /admin/stats — simple JSON usage stats (admin API key required).
function _M.stats()
    _M.init()
    apikey.require_admin()
    local s = metadata.stats()
    local vips = require "image.vips_ffi"
    local l1 = require "image.l1cache"
    local guard_cfg = download_guard.config()
    local bw, reqs = download_guard.recent_bandwidth(24)
    ngx.header.content_type = "application/json"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode({
        images = tonumber(s.cnt) or 0,
        total_bytes = tonumber(s.total) or 0,
        vips_available = vips.available(),
        l1_capacity = l1.capacity(),
        l1_free = l1.free_space(),
        download = guard_cfg,
        bandwidth_24h_bytes = bw,
        requests_24h = reqs,
    }))
    ngx.exit(200)
end

-- GET /admin/usage — per-key usage leaderboard (admin).
function _M.usage_report()
    _M.init()
    apikey.require_admin()
    local args = ngx.req.get_uri_args()
    local limit = util.parse_int(args.limit, 50, 1, 200)
    local rows = metadata.usage_leaderboard(limit)
    ngx.header.content_type = "application/json"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode({ usage = rows }))
    ngx.exit(200)
end

-- GET /me/images — list images uploaded by the calling key (any role).
function _M.my_images()
    _M.init()
    local subject = apikey.require()
    local args = ngx.req.get_uri_args()
    local limit = util.parse_int(args.limit, 50, 1, 200)
    local offset = util.parse_int(args.offset, 0, 0, 100000)
    local rows = metadata.list_by_owner(subject.hash, limit, offset)
    local base = ngx.var.scheme .. "://" .. ngx.var.host
    for _, r in ipairs(rows) do
        r.url = base .. "/i/" .. r.hash .. "." .. r.orig_ext
        r.owner = nil  -- hash is not useful to the caller
    end
    ngx.header.content_type = "application/json"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode({ images = rows, limit = limit, offset = offset }))
    ngx.exit(200)
end

-- GET /sign?path=/i/<hash>.jpg&w=800&fmt=webp&ttl=3600
-- Returns a signed URL. Requires an API key so arbitrary paths cannot be
-- signed by anonymous visitors; the key is not embedded in the URL. Each key
-- is capped at 60 sign/min to prevent this endpoint from being used as an
-- oracle.
function _M.sign()
    _M.init()
    local subject = apikey.require()
    local rate_limit = require "common.rate_limit"
    if not rate_limit.check_upload_limit(subject.hash) then
        rate_limit.block_request("sign_rate_limit_exceeded")
    end
    local args = ngx.req.get_uri_args()
    local path = args.path
    if not path or path:sub(1, 1) ~= "/" then
        util.bad_request("path must start with /")
    end
    -- Only allow signing paths under /i/ so callers cannot mint signatures
    -- for arbitrary routes (the upload/admin endpoints don't check s=...).
    if not path:match("^/i/") then
        util.bad_request("only /i/ paths can be signed")
    end
    local ttl = util.parse_int(args.ttl, 3600, 30, 7 * 86400)
    local signable = { "w", "h", "q", "fmt", "fit", "wm", "gray", "blur",
                       "download" }
    local params = {}
    for _, k in ipairs(signable) do
        if args[k] ~= nil then params[k] = args[k] end
    end
    local qs = download_guard.sign_path(path, ttl, params)
    local base = ngx.var.scheme .. "://" .. ngx.var.host
    ngx.header.content_type = "application/json"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode({
        url = base .. path .. "?" .. qs,
        path = path,
        ttl = ttl,
        expires_at = ngx.time() + ttl,
    }))
    ngx.exit(200)
end

-- GET /i/<hash>/info — public JSON metadata (dimensions, size, mime).
function _M.image_info()
    _M.init()
    local uri = ngx.var.uri
    local hash = uri:match("^/i/([0-9a-fA-F]+)/info$")
    if not hash then util.not_found("invalid hash") end
    hash = hash:lower()
    local meta = metadata.get_image(hash)
    if not meta then util.not_found("image not found") end
    ngx.header.content_type = "application/json"
    ngx.header["Cache-Control"] = "public, max-age=300"
    local cjson = require "cjson.safe"
    local body = {
        hash = meta.hash,
        mime = meta.mime,
        size = tonumber(meta.size_bytes),
        width = tonumber(meta.width),
        height = tonumber(meta.height),
        uploaded_at = tonumber(meta.uploaded_at),
        ext = meta.orig_ext,
    }
    ngx.say(cjson.encode(body))
    ngx.exit(200)
end

-- GET /me — minimal HTML self-service page listing the caller's images.
function _M.me_page()
    _M.init()
    local subject = apikey.require()
    local args = ngx.req.get_uri_args()
    local limit = util.parse_int(args.per, 60, 10, 200)
    local offset = util.parse_int(args.page, 1, 1, 100000) - 1
    offset = offset * limit
    local rows = metadata.list_by_owner(subject.hash, limit, offset)
    local total = metadata.count(subject.hash)
    local used_bytes = metadata.usage_for(subject.hash)
    local base = ngx.var.scheme .. "://" .. ngx.var.host
    local t = require "image.i18n".bind(ngx.var.http_accept_language)

    local items = {}
    for _, r in ipairs(rows) do
        local url = base .. "/i/" .. r.hash .. "." .. r.orig_ext
        items[#items+1] = string.format(
            '<figure><a href="%s" target=_blank><img loading=lazy src="%s?w=240"></a>'
            .. '<figcaption><code>%s</code><br><span class=meta>%s · %s</span></figcaption></figure>',
            url, url, r.hash:sub(1,12),
            util.human_size(tonumber(r.size_bytes) or 0), r.orig_ext)
    end

    local quota_line
    if subject.quota and subject.quota > 0 then
        local pct = math.floor(used_bytes * 100 / subject.quota)
        quota_line = string.format(
            '<div class=card><div class=n>%s / %s</div>'
            .. '<div class=l>%s (%d%%)</div></div>',
            util.human_size(used_bytes), util.human_size(subject.quota),
            t.total_size, pct)
    else
        quota_line = string.format(
            '<div class=card><div class=n>%s</div><div class=l>%s</div></div>',
            util.human_size(used_bytes), t.total_size)
    end

    local html = string.format([[<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>%s</title>
<style>
body{font-family:system-ui;max-width:1000px;margin:24px auto;padding:0 16px}
h1{font-size:1.3rem}.stats{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0 20px}
.card{border:1px solid #e5e7eb;border-radius:10px;padding:10px 14px;min-width:130px}
.card .n{font-size:1.3rem;font-weight:600}.card .l{color:#666;font-size:.8rem}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:14px}
figure{margin:0;border:1px solid #eee;border-radius:8px;overflow:hidden}
figure img{width:100%%;height:130px;object-fit:cover;display:block;background:#f6f6f6}
figcaption{padding:8px;font-size:12px}code{word-break:break-all}.meta{color:#888}
a.back{color:#2563eb;text-decoration:none}
</style></head><body>
<h1>%s</h1>
<p><a class=back href="/upload">%s</a></p>
<div class=stats>
  <div class=card><div class=n>%d</div><div class=l>%s</div></div>
  %s
</div>
<div class=grid>%s</div>
</body></html>]],
        t.upload_title, t.upload_title, t.back_to_upload,
        total, t.total_images, quota_line, table.concat(items))
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(html)
    ngx.exit(200)
end

-- GET /i/<hash>/view — image detail HTML page.
function _M.image_page()
    _M.init()
    local hash = extract_hash(ngx.var.uri)
    if not hash then util.not_found() end
    local meta = metadata.get_image(hash)
    if not meta then util.not_found() end
    local base = ngx.var.scheme .. "://" .. ngx.var.host
    local url = base .. "/i/" .. hash .. "." .. meta.orig_ext
    local md = "![](" .. url .. ")"
    local html_tag = '<img src="' .. url .. '">'
    local t = require "image.i18n".bind(ngx.var.http_accept_language)
    local body = string.format([[<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>%s</title>
<style>
body{font-family:system-ui;max-width:900px;margin:24px auto;padding:0 16px;color:#222}
img{max-width:100%%;height:auto;border-radius:8px;background:#f6f6f6}
pre{background:#f6f6f6;padding:8px;border-radius:6px;overflow:auto;font-size:12px}
.meta{color:#666;font-size:.9rem}
a.back{color:#2563eb;text-decoration:none}
</style><body>
<p><a class=back href=/>%s</a></p>
<img src="%s?w=1024" alt="">
<p class=meta>%s · %dx%d · %s</p>
<h3>Markdown</h3><pre>%s</pre>
<h3>HTML</h3><pre>%s</pre>
<h3>URL</h3><pre>%s</pre>
</body></html>]],
        hash:sub(1,12), t.back_to_upload, url,
        meta.mime, tonumber(meta.width) or 0, tonumber(meta.height) or 0,
        util.human_size(tonumber(meta.size_bytes) or 0),
        md, html_tag, url)
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(body)
    ngx.exit(200)
end

-- GET /admin — minimal HTML admin panel (admin key required). Shows usage
-- stats, bandwidth, and a paginated/filterable/batch-deletable gallery.
function _M.admin()
    _M.init()
    local subject = apikey.require_admin()
    local args = ngx.req.get_uri_args()
    local page   = util.parse_int(args.page, 1, 1, 10000)
    local per    = util.parse_int(args.per, 60, 10, 200)
    local owner  = args.owner or ""
    local offset = (page - 1) * per

    local s = metadata.stats()
    local rows = metadata.recent(per, owner ~= "" and owner or nil, offset)
    local total = metadata.count(owner ~= "" and owner or nil)
    local pages = math.max(1, math.ceil(total / per))

    local base = ngx.var.scheme .. "://" .. ngx.var.host
    local vips = require "image.vips_ffi"
    local l1 = require "image.l1cache"
    local bw, reqs = download_guard.recent_bandwidth(24)

    local items = {}
    for _, r in ipairs(rows) do
        local url = base .. "/i/" .. r.hash .. "." .. r.orig_ext
        local owner_label = (r.uploaded_by or "unknown"):sub(1, 12)
        items[#items + 1] = string.format(
            '<figure>'
            .. '<label class="pick"><input type="checkbox" data-hash="%s"></label>'
            .. '<img loading="lazy" src="%s?w=320" alt="%s">'
            .. '<figcaption><code>%s</code><br><span class="meta">%s · %s · %s</span>'
            .. '<button data-hash="%s">删除</button></figcaption>'
            .. '</figure>',
            r.hash, url, r.hash, r.hash:sub(1, 12),
            util.human_size(tonumber(r.size_bytes) or 0),
            r.orig_ext, owner_label, r.hash)
    end

    -- Build pagination links preserving the current filter.
    local function page_link(n)
        local q = "?page=" .. n .. "&per=" .. per
                 .. (owner ~= "" and ("&owner=" .. ngx.escape_uri(owner)) or "")
        return ngx.var.uri .. q
    end
    local pager = {}
    for n = math.max(1, page - 3), math.min(pages, page + 3) do
        if n == page then
            pager[#pager + 1] = "<span class=\"cur\">" .. n .. "</span>"
        else
            pager[#pager + 1] = "<a href=\"" .. page_link(n) .. "\">" .. n .. "</a>"
        end
    end

    local html = string.format([[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s · 管理</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:1100px;margin:24px auto;padding:0 16px;color:#222}
 h1{font-size:1.3rem}
 .stats{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0 20px}
 .card{border:1px solid #e5e7eb;border-radius:10px;padding:10px 14px;min-width:130px}
 .card .n{font-size:1.3rem;font-weight:600}
 .card .l{color:#666;font-size:.8rem}
 .toolbar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:16px}
 .toolbar input[type=text]{padding:6px 8px;border:1px solid #ccc;border-radius:6px;min-width:200px}
 .toolbar button,.batch{cursor:pointer;border-radius:6px;padding:6px 12px;border:1px solid #ccc;background:#fff}
 .batch{color:#b91c1c;border-color:#fca5a5}
 .batch:hover{background:#fef2f2}
 .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:14px}
 figure{position:relative;margin:0;border:1px solid #eee;border-radius:8px;overflow:hidden}
 figure .pick{position:absolute;top:6px;left:6px;background:rgba(255,255,255,.85);
            padding:2px 4px;border-radius:4px}
 figure img{width:100%%;height:130px;object-fit:cover;display:block;background:#f6f6f6}
 figcaption{padding:8px;font-size:12px}
 figcaption code{word-break:break-all}
 .meta{color:#888}
 figure button{margin-top:6px;cursor:pointer;color:#b91c1c;border:1px solid #fca5a5;
              background:#fff;border-radius:6px;padding:3px 8px}
 .pager{margin-top:24px;display:flex;gap:8px;align-items:center}
 .pager a,.pager span{padding:4px 10px;border:1px solid #e5e7eb;border-radius:6px;text-decoration:none;color:#333}
 .pager .cur{background:#2563eb;color:#fff;border-color:#2563eb}
 a.back{color:#2563eb;text-decoration:none}
</style></head><body>
<h1>%s</h1>
<p><a class="back" href="/upload">← 返回上传</a>
   &nbsp;·&nbsp; <a href="/admin/stats">/admin/stats</a>
   &nbsp;·&nbsp; <a href="/admin/usage">/admin/usage</a>
   · <a href="/admin/analytics">统计</a></p>
<div class="stats">
  <div class="card"><div class="n">%d</div><div class="l">图片总数</div></div>
  <div class="card"><div class="n">%s</div><div class="l">原始体积</div></div>
  <div class="card"><div class="n">%s / %s</div><div class="l">L1 缓存 (free/cap)</div></div>
  <div class="card"><div class="n">%s</div><div class="l">24h 下载量</div></div>
  <div class="card"><div class="n">%s</div><div class="l">24h 请求数</div></div>
  <div class="card"><div class="n">%s</div><div class="l">libvips</div></div>
</div>
<form class="toolbar" method="get" action="/admin">
  <input type="text" name="owner" placeholder="按 owner (key hash 前缀)" value="%s" pattern="[0-9a-fA-F]*">
  <input type="hidden" name="per" value="%d">
  <button type="submit">筛选</button>
  <button type="button" class="batch" id="bulk">批量删除选中</button>
</form>
<div class="grid">%s</div>
<div class="pager">%s</div>
<script>
const key=new URLSearchParams(location.search).get('api_key')||'';
const auth=key?{'Authorization':'Bearer '+key}:{};
document.querySelectorAll('figure button[data-hash]').forEach(b=>{
  b.onclick=async()=>{
    if(!confirm('确认删除这张图片？'))return;
    const h=b.dataset.hash;
    const r=await fetch('/i/'+h,{method:'DELETE',headers:auth});
    if(r.status===204){b.closest('figure').remove();}
    else{alert('删除失败: '+r.status);}
  };
});
document.getElementById('bulk').onclick=async()=>{
  const hashes=[...document.querySelectorAll('figure input:checked')].map(i=>i.dataset.hash);
  if(!hashes.length){alert('未选中任何图片');return;}
  if(!confirm('确认删除选中的 '+hashes.length+' 张图片？'))return;
  let ok=0;
  for(const h of hashes){
    const r=await fetch('/i/'+h,{method:'DELETE',headers:auth});
    if(r.status===204){document.querySelector('figure input[data-hash="'+h+'"]').closest('figure').remove();ok++;}
  }
  alert('已删除 '+ok+' / '+hashes.length);
};
</script>
</body></html>]],
        config.upload_page_title, config.upload_page_title,
        tonumber(s.cnt) or 0,
        util.human_size(tonumber(s.total) or 0),
        util.human_size(l1.free_space()), util.human_size(l1.capacity()),
        util.human_size(bw),
        tostring(reqs),
        vips.available() and "可用" or "未加载",
        util.html_escape(owner), per,
        table.concat(items),
        table.concat(pager))

    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(html)
    ngx.exit(200)
end

-- GET /admin/analytics — download stats and hotspot analysis page.
-- Shows a 30-day download/bytes chart (pure SVG, no external JS) and a
-- grid of the hottest images. Rendered in the same style as /admin.
function _M.analytics()
    _M.init()
    apikey.require_admin()
    local days = 30
    local series = metadata.stats_series(days)
    local hot = metadata.hot_images(days, 30)
    local s = metadata.stats()
    -- Aggregate totals from the series (or scan at DB level).
    local total_req, total_bw, max_req = 0, 0, 0
    for _, row in ipairs(series) do
        local c = tonumber(row.count) or 0
        total_req = total_req + c
        total_bw  = total_bw + (tonumber(row.bytes) or 0)
        if c > max_req then max_req = c end
    end
    local base = ngx.var.scheme .. "://" .. ngx.var.host

    -- Build SVG bars. Chart width = 700, height = 140.
    local chart_w, chart_h = 700, 140
    local bar_w = math.max(8, math.min(20, math.floor(chart_w / #series)))
    local pad_left = 5
    local max_h = math.max(1, max_req)
    local bars = {}
    for i, row in ipairs(series) do
        local h = math.max(1, math.floor(tonumber(row.count or 0) / max_h * (chart_h - 8)))
        local x = pad_left + (i - 1) * (bar_w + 2)
        local y = chart_h - 4 - h
        local day = tostring(row.day or "?"):sub(-4)
        bars[#bars + 1] = string.format(
            '<rect x="%d" y="%d" width="%d" height="%d" fill="#3b82f6" rx="2"><title>%s: %d</title></rect>',
            x, y, bar_w, h, day, tonumber(row.count) or 0)
    end

    -- Hotspot grid.
    local grid_items = {}
    for i, row in ipairs(hot) do
        local h = row.hash or ""
        local url = base .. "/i/" .. h .. ".jpg"  -- generic ext; /i/ handles it
        local thumb = base .. "/i/" .. h .. "?w=160"
        grid_items[#grid_items + 1] = string.format(
            '<figure>'
            .. '<span class="rank">#%d</span>'
            .. '<img loading="lazy" src="%s" alt="%s">'
            .. '<figcaption><code>%s</code><br><span class="meta">%d 次 · %s</span></figcaption>'
            .. '</figure>',
            i, thumb, h, h:sub(1, 12),
            tonumber(row.count) or 0,
            util.human_size(tonumber(row.bytes) or 0))
    end

    local title = config.upload_page_title
    local html = string.format([[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s · 统计</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:960px;margin:24px auto;padding:0 16px;color:#222}
 h1{font-size:1.3rem}
 .stats{display:flex;gap:12px;flex-wrap:wrap;margin:12px 0 20px}
 .card{border:1px solid #e5e7eb;border-radius:10px;padding:10px 14px;min-width:130px}
 .card .n{font-size:1.3rem;font-weight:600}
 .card .l{color:#666;font-size:.8rem}
 .chart{background:#f9fafb;border-radius:8px;padding:12px;overflow-x:auto;margin-bottom:20px}
 .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px}
 figure{position:relative;margin:0;border:1px solid #eee;border-radius:8px;overflow:hidden}
 figure .rank{position:absolute;top:4px;left:4px;background:rgba(0,0,0,.5);color:#fff;
      font-size:11px;padding:1px 6px;border-radius:4px}
 figure img{width:100%%;height:100px;object-fit:cover;display:block;background:#f6f6f6}
 figcaption{padding:6px;font-size:11px}
 .meta{color:#888}
</style></head><body>
<h1>%s · 访问统计</h1>
<p><a class="back" href="/admin" style="color:#2563eb">← 返回管理</a></p>
<div class="stats">
  <div class="card"><div class="n">%d</div><div class="l">图片总数</div></div>
  <div class="card"><div class="n">%s</div><div class="l">30d 下载量</div></div>
  <div class="card"><div class="n">%s</div><div class="l">30d 流量</div></div>
  <div class="card"><div class="n">%d</div><div class="l">30d 热点图片</div></div>
</div>
<div class="chart"><svg width="%d" height="%d" xmlns="http://www.w3.org/2000/svg">%s
<text x="%d" y="%d" font-size="11" fill="#999">← 更早</text>
<text x="%d" y="%d" font-size="11" fill="#999" text-anchor="end">最近 →</text>
</svg></div>
<h2>热点图片</h2>
<div class="grid">%s</div>
</body></html>]],
        title, title,
        tonumber(s.cnt) or 0,
        util.human_size(total_req),
        util.human_size(total_bw),
        #hot,
        chart_w, chart_h, table.concat(bars),
        pad_left, chart_h + 8,
        pad_left + #series * (bar_w + 2) - bar_w, chart_h + 8)

    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(html)
    ngx.exit(200)
end

return _M
