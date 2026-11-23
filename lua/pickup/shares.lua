-- Shares: a set of stored blobs published under a short link (slug) and a
-- numeric pickup code, with an expiry and an optional visit limit.
local metadata = require "image.metadata"
local pconfig = require "pickup.config"
local sniff = require "pickup.sniff"
local secret = require "pickup.secret"
local crypto = require "common.crypto"
local rand = require "common.rand"
local ngx = ngx

local _M = {}

local SHARE_COLS = [[id, slug, code, title, owner, owner_name, created_at, expires_at,
    max_visits, visit_count, revoked, file_count, total_bytes]]

-- ---------------------------------------------------------------- names --

-- Replace invalid UTF-8 sequences with "?" so names are safe for JSON/HTML.
function _M.valid_utf8(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else len = 0 end
        local ok = len > 0 and i + len - 1 <= n
        if ok then
            for k = i + 1, i + len - 1 do
                local cc = s:byte(k)
                if cc < 0x80 or cc > 0xBF then ok = false; break end
            end
        end
        if ok then
            out[#out + 1] = s:sub(i, i + len - 1)
            i = i + len
        else
            out[#out + 1] = "?"
            i = i + 1
        end
    end
    return table.concat(out)
end

-- Truncate to at most `max` bytes without splitting a UTF-8 sequence.
local function utf8_truncate(s, max)
    if #s <= max then return s end
    local cut = max
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- Make an untrusted file name safe for display, Content-Disposition and zip
-- entries: base name only, no control or reserved characters, bounded size.
function _M.clean_name(name, seq)
    name = _M.valid_utf8(tostring(name or ""))
    name = name:gsub("^.*[/\\]", "")            -- strip directories
    name = name:gsub("[%z\1-\31\127]", "")      -- control characters
    name = name:gsub('[<>:"|%?%*]', "_")        -- reserved on Windows
    name = name:gsub("^%s+", ""):gsub("[%s%.]+$", "")
    name = name:gsub("^%.+", "_")
    name = utf8_truncate(name, 180)
    if name == "" then name = "file-" .. tostring(seq or 1) end
    return name
end

-- Make names unique within a share: "a.jpg", "a (2).jpg", ...
function _M.dedupe_names(names)
    local seen, out = {}, {}
    for i, n in ipairs(names) do
        local key = n:lower()
        if seen[key] then
            local stem, ext = n:match("^(.*)(%.[^%.]+)$")
            if not stem or stem == "" then stem, ext = n, "" end
            local k = 2
            local cand
            repeat
                cand = stem .. " (" .. k .. ")" .. ext
                k = k + 1
            until not seen[cand:lower()]
            n = cand
            key = n:lower()
        end
        seen[key] = true
        out[i] = n
    end
    return out
end

-- --------------------------------------------------------------- lookup --

function _M.get(id)
    return metadata.row("SELECT " .. SHARE_COLS .. " FROM shares WHERE id=?", tonumber(id))
end

function _M.get_by_slug(slug)
    if type(slug) ~= "string" or not slug:match("^[%w]+$") or #slug > 32 then return nil end
    return metadata.row("SELECT " .. SHARE_COLS .. " FROM shares WHERE slug=?", slug)
end

-- Live shares only: a dead share's code may already belong to a new one.
function _M.get_by_code(code)
    if type(code) ~= "string" or not code:match("^%d+$") then return nil end
    return metadata.row("SELECT " .. SHARE_COLS
        .. " FROM shares WHERE code=? AND revoked=0 AND expires_at>?", code, ngx.time())
end

function _M.files(share_id)
    return metadata.rows([[SELECT sf.seq, sf.blob_hash, sf.name, sf.size_bytes, sf.mime, sf.kind,
            i.orig_ext, i.crc32, i.width, i.height
        FROM share_files sf LEFT JOIN images i ON i.hash = sf.blob_hash
        WHERE sf.share_id=? ORDER BY sf.seq]], share_id)
end

function _M.file(share_id, seq)
    return metadata.row([[SELECT sf.seq, sf.blob_hash, sf.name, sf.size_bytes, sf.mime, sf.kind,
            i.orig_ext, i.crc32, i.width, i.height
        FROM share_files sf LEFT JOIN images i ON i.hash = sf.blob_hash
        WHERE sf.share_id=? AND sf.seq=?]], share_id, tonumber(seq))
end

-- "live" | "expired" | "revoked" | "exhausted"
function _M.state(share, now)
    now = now or ngx.time()
    if tonumber(share.revoked) == 1 then return "revoked" end
    if tonumber(share.expires_at) <= now then return "expired" end
    local maxv = tonumber(share.max_visits) or 0
    if maxv > 0 and (tonumber(share.visit_count) or 0) >= maxv then return "exhausted" end
    return "live"
end

-- --------------------------------------------------------------- create --

-- files: array of { hash = sha256hex, name = string }
-- opts:  { expires_in = seconds, max_visits = n, title = string }
-- Returns the share row or nil, error_code, http_status.
function _M.create(subject, files, opts)
    opts = opts or {}
    if type(files) ~= "table" or #files == 0 then return nil, "no_files", 400 end
    if #files > pconfig.max_files then return nil, "too_many_files", 400 end

    local expires_in = tonumber(opts.expires_in) or pconfig.default_expiry
    if expires_in < pconfig.min_expiry or expires_in > pconfig.max_expiry then
        return nil, "invalid_expiry", 400
    end
    local max_visits = math.floor(tonumber(opts.max_visits) or 0)
    if max_visits < 0 or max_visits > pconfig.max_visits_limit then
        return nil, "invalid_max_visits", 400
    end
    local title = _M.clean_name(opts.title or "", 0)
    if title == "file-0" then title = "" end

    local names, hashes = {}, {}
    for i, f in ipairs(files) do
        if type(f) ~= "table" or type(f.hash) ~= "string" or not f.hash:match("^%x+$") or #f.hash ~= 64 then
            return nil, "invalid_file", 400
        end
        hashes[i] = f.hash:lower()
        names[i] = _M.clean_name(f.name, i)
    end
    names = _M.dedupe_names(names)

    local now = ngx.time()
    local ok, res = pcall(metadata.tx, function(db)
        local blobs, total = {}, 0
        for i, h in ipairs(hashes) do
            local b = db:query_row("SELECT hash, size_bytes, mime, kind FROM images WHERE hash=? AND deleted=0", h)
            if not b then error({ code = "missing_file", index = i }) end
            blobs[i] = b
            total = total + tonumber(b.size_bytes)
        end

        local slug
        for _ = 1, 10 do
            local cand = rand.base62(pconfig.slug_length)
            if not db:query_row("SELECT 1 AS x FROM shares WHERE slug=?", cand) then slug = cand break end
        end
        local code
        for _ = 1, 50 do
            local cand = rand.digits(pconfig.code_length)
            if not db:query_row("SELECT 1 AS x FROM shares WHERE code=?", cand) then code = cand break end
        end
        if not slug or not code then error({ code = "no_free_code" }) end

        db:run([[INSERT INTO shares(slug, code, title, owner, owner_name, created_at, expires_at,
                    max_visits, visit_count, revoked, file_count, total_bytes)
                 VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)]],
            slug, code, title, subject.hash, subject.name or "", now, now + expires_in,
            max_visits, #hashes, total)
        local id = db:last_insert_rowid()
        for i, b in ipairs(blobs) do
            local mime = b.mime
            if b.kind == "other" then mime = sniff.mime_for_name(names[i]) end
            db:run([[INSERT INTO share_files(share_id, seq, blob_hash, name, size_bytes, mime, kind)
                     VALUES(?, ?, ?, ?, ?, ?, ?)]],
                id, i, b.hash, names[i], tonumber(b.size_bytes), mime, b.kind or "other")
        end
        return id
    end)
    if not ok then
        local code = type(res) == "table" and res.code or "db_error"
        if code == "db_error" then
            require("common.logger").err("share_create_failed", { error = tostring(res) })
        end
        return nil, code, (code == "missing_file") and 409 or ((code == "db_error") and 500 or 503)
    end
    require("common.metrics").incr("shares_created")
    return _M.get(res)
end

-- ---------------------------------------------------------- mutations --

-- Count one visit. Returns true, or false when the share is no longer live
-- (including when the visit limit was just reached by someone else).
function _M.consume_visit(share)
    local ok, changed = pcall(metadata.write, function(db)
        db:run([[UPDATE shares SET visit_count = visit_count + 1
                 WHERE id=? AND revoked=0 AND expires_at>?
                   AND (max_visits=0 OR visit_count < max_visits)]], share.id, ngx.time())
        return db:changes()
    end)
    if ok and changed == 1 then
        require("common.metrics").incr("share_visits")
        return true
    end
    return false
end

local function can_manage(share, subject)
    return share and (subject.role == "admin" or share.owner == subject.hash)
end
_M.can_manage = can_manage

function _M.revoke(share, subject)
    if not can_manage(share, subject) then return nil, "not_found", 404 end
    local now = ngx.time()
    metadata.write(function(db)
        db:run("UPDATE shares SET revoked=1, code=NULL, expires_at=MIN(expires_at, ?) WHERE id=?",
               now, share.id)
    end)
    return _M.get(share.id)
end

-- Set the remaining lifetime to `seconds` from now (live shares only).
function _M.extend(share, subject, seconds)
    if not can_manage(share, subject) then return nil, "not_found", 404 end
    if _M.state(share) == "revoked" or _M.state(share) == "expired" then
        return nil, "not_live", 409
    end
    seconds = tonumber(seconds)
    if not seconds or seconds < pconfig.min_expiry or seconds > pconfig.max_expiry then
        return nil, "invalid_expiry", 400
    end
    metadata.write(function(db)
        db:run("UPDATE shares SET expires_at=? WHERE id=?", ngx.time() + seconds, share.id)
    end)
    return _M.get(share.id)
end

function _M.list(owner_hash, limit, offset)
    limit = math.min(math.max(tonumber(limit) or 50, 1), 200)
    offset = math.max(tonumber(offset) or 0, 0)
    if owner_hash then
        return metadata.rows("SELECT " .. SHARE_COLS
            .. " FROM shares WHERE owner=? ORDER BY id DESC LIMIT ? OFFSET ?", owner_hash, limit, offset)
    end
    return metadata.rows("SELECT " .. SHARE_COLS
        .. " FROM shares ORDER BY id DESC LIMIT ? OFFSET ?", limit, offset)
end

-- -------------------------------------------------------------- tokens --
-- A recipient token proves the holder opened the pickup page (or is the
-- owner previewing it); it lets them reload the page and download files
-- without consuming further visits until it expires.

local function sign(share, exp)
    local msg = "t1|" .. share.id .. "|" .. share.slug .. "|" .. exp
    return crypto.hmac_sha256_hex(secret.get(), msg):sub(1, 32)
end

function _M.mint_token(share, ttl)
    local exp = math.min(ngx.time() + (ttl or pconfig.token_ttl), tonumber(share.expires_at))
    return exp .. "." .. sign(share, exp)
end

function _M.verify_token(share, token)
    if type(token) ~= "string" then return false end
    local exp, sig = token:match("^(%d+)%.(%x+)$")
    exp = tonumber(exp)
    if not exp or exp < ngx.time() then return false end
    return crypto.const_eq(sig, sign(share, exp))
end

-- ------------------------------------------------------------- views --

function _M.public_url(path)
    local base = pconfig.public_url
    if not base then
        local scheme = ngx.var.scheme
        local trusted = os.getenv("TRUST_X_FORWARDED_FOR")
        if (trusted == "true" or trusted == "1") and ngx.var.http_x_forwarded_proto then
            scheme = ngx.var.http_x_forwarded_proto:match("^(%a+)") or scheme
        end
        local host = ngx.var.http_host or ngx.var.host or "localhost"
        if not host:match("^[%w%.%-:%[%]]+$") then host = ngx.var.host or "localhost" end
        base = scheme .. "://" .. host
    end
    return base .. path
end

function _M.to_json(share, files)
    local now = ngx.time()
    local out = {
        id = share.id, slug = share.slug, code = share.code, title = share.title,
        owner = share.owner_name, created_at = share.created_at, expires_at = share.expires_at,
        expires_in = math.max(0, share.expires_at - now), max_visits = share.max_visits,
        visit_count = share.visit_count, state = _M.state(share, now),
        file_count = share.file_count, total_bytes = share.total_bytes,
        url = _M.public_url("/p/" .. share.slug),
        qr_url = _M.public_url("/p/" .. share.slug .. "/qr.svg"),
    }
    if share.code then out.code_url = _M.public_url("/c/" .. share.code) end
    if files then
        local list = {}
        for _, f in ipairs(files) do
            list[#list + 1] = { seq = f.seq, name = f.name, size = f.size_bytes, kind = f.kind }
        end
        out.files = list
    end
    return out
end

return _M
