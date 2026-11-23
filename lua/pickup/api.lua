-- JSON API under /api/. Authentication: `Authorization: Bearer <password>`.
--
--   GET    /api/config                  public limits for the UI
--   GET    /api/me                      who am I, quota usage
--   POST   /api/upload[?share=1&...]    multipart upload (optionally share at once)
--   POST   /api/shares                  {files:[{hash,name}], expires_in, max_visits, title}
--   GET    /api/shares[?all=1]          list (admins may list everyone's)
--   GET    /api/shares/<id>             details incl. files
--   POST   /api/shares/<id>/revoke      stop sharing now
--   POST   /api/shares/<id>/extend      {expires_in}
--   POST   /api/shares/<id>/preview     owner link that does not count a visit
--   DELETE /api/shares/<id>             same as revoke
local cjson = require "cjson.safe"
local apikey = require "image.apikey"
local upload = require "image.upload"
local metadata = require "image.metadata"
local pconfig = require "pickup.config"
local shares = require "pickup.shares"
local ngx = ngx

local _M = {}

local MESSAGES = {
    no_files = "没有选择文件", too_many_files = "文件数量超过上限",
    invalid_expiry = "有效期超出允许范围", invalid_max_visits = "可打开次数无效",
    invalid_file = "文件参数无效", missing_file = "有文件已过期被清理，请重新上传",
    quota_exceeded = "上传额度已用完", disk_full = "服务器存储空间不足",
    file_too_large = "文件超过大小上限", not_found = "分享不存在", not_live = "分享已失效",
    bad_json = "请求格式错误", no_free_code = "暂时无法分配取件码，请重试",
}

local function json(status, obj)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    ngx.print(cjson.encode(obj))
    return ngx.exit(status)
end
_M.json = json

local function fail(status, code)
    return json(status or 400, { error = code, message = MESSAGES[code] or code })
end

local function read_json()
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if not data then
        local path = ngx.req.get_body_file()
        if path then
            local f = io.open(path, "rb")
            if f then data = f:read("*a"); f:close() end
        end
    end
    if not data or data == "" then return {} end
    if #data > 1024 * 1024 then return nil end
    local obj = cjson.decode(data)
    if type(obj) ~= "table" then return nil end
    return obj
end

local function share_or_404(id, subject)
    local share = shares.get(id)
    if not share or not shares.can_manage(share, subject) then return fail(404, "not_found") end
    return share
end

local function expiry_arg(v)
    if v == nil or v == "" then return nil end
    return tonumber(v) or pconfig.parse_duration(v)
end

function _M.config()
    return json(200, {
        site_name = pconfig.site_name, max_file_bytes = pconfig.max_file_bytes,
        max_files = pconfig.max_files, default_expiry = pconfig.default_expiry,
        min_expiry = pconfig.min_expiry, max_expiry = pconfig.max_expiry,
        expiry_choices = pconfig.expiry_choices, code_length = pconfig.code_length,
    })
end

function _M.me()
    local subject = apikey.require()
    local left, quota, used = upload.quota_left(subject)
    return json(200, {
        name = subject.name, role = subject.role,
        quota_bytes = quota, used_bytes = used or metadata.usage_for(subject.hash),
        left_bytes = left,
    })
end

function _M.upload()
    local subject = apikey.require()
    local got, code, status = upload.receive_multipart(subject)
    if not got then return fail(status, code) end
    local out = {}
    for _, item in ipairs(got) do out[#out + 1] = upload.describe(item.blob, item.name) end
    local args = ngx.req.get_uri_args()
    if args.share == "1" or args.share == "true" then
        local list = {}
        for _, item in ipairs(got) do list[#list + 1] = { hash = item.blob.hash, name = item.name } end
        local share, scode, sstatus = shares.create(subject, list, {
            expires_in = expiry_arg(args.expires_in or args.expires),
            max_visits = args.max_visits, title = args.title,
        })
        if not share then return fail(sstatus, scode) end
        local res = shares.to_json(share, shares.files(share.id))
        res.uploaded = out
        return json(201, res)
    end
    return json(201, { files = out })
end

function _M.create_share()
    local subject = apikey.require()
    local body = read_json()
    if not body then return fail(400, "bad_json") end
    local share, code, status = shares.create(subject, body.files, {
        expires_in = expiry_arg(body.expires_in), max_visits = body.max_visits, title = body.title,
    })
    if not share then return fail(status, code) end
    return json(201, shares.to_json(share, shares.files(share.id)))
end

function _M.list_shares()
    local subject = apikey.require()
    local args = ngx.req.get_uri_args()
    local owner = subject.hash
    if subject.role == "admin" and (args.all == "1" or args.all == "true") then owner = nil end
    local rows = shares.list(owner, args.limit, args.offset)
    local out = {}
    for _, s in ipairs(rows) do out[#out + 1] = shares.to_json(s) end
    return json(200, { shares = out })
end

function _M.share_action(id, action)
    local subject = apikey.require()
    local method = ngx.req.get_method()
    local share = share_or_404(id, subject)
    if not action and method == "GET" then
        return json(200, shares.to_json(share, shares.files(share.id)))
    end
    if (action == "revoke" and method == "POST") or (not action and method == "DELETE") then
        local s, code, status = shares.revoke(share, subject)
        if not s then return fail(status, code) end
        return json(200, shares.to_json(s))
    end
    if action == "extend" and method == "POST" then
        local body = read_json() or {}
        local s, code, status = shares.extend(share, subject, expiry_arg(body.expires_in) or pconfig.default_expiry)
        if not s then return fail(status, code) end
        return json(200, shares.to_json(s))
    end
    if action == "preview" and method == "POST" then
        if shares.state(share) == "revoked" or shares.state(share) == "expired" then
            return fail(409, "not_live")
        end
        local t = shares.mint_token(share)
        return json(200, { url = shares.public_url("/p/" .. share.slug .. "?t=" .. ngx.escape_uri(t)) })
    end
    return fail(405, "method_not_allowed")
end

function _M.dispatch()
    local uri = ngx.var.uri
    local method = ngx.req.get_method()
    if uri == "/api/config" and method == "GET" then return _M.config() end
    if uri == "/api/me" and method == "GET" then return _M.me() end
    if uri == "/api/upload" and method == "POST" then return _M.upload() end
    if uri == "/api/shares" then
        if method == "POST" then return _M.create_share() end
        if method == "GET" then return _M.list_shares() end
        return fail(405, "method_not_allowed")
    end
    local id, action = uri:match("^/api/shares/(%d+)/?(%a*)$")
    if id then return _M.share_action(id, action ~= "" and action or nil) end
    return fail(404, "not_found")
end

return _M
