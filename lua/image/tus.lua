-- tus 1.0 resumable uploads (core protocol + creation, expiration,
-- termination and checksum extensions) for large files over flaky links.
--
-- PATCH bodies are streamed from the client socket straight into the
-- session's part file, so memory use is constant and a dropped connection
-- keeps whatever already arrived: the client asks HEAD for the offset and
-- continues from there. When the last byte lands the part file becomes a
-- blob via upload.store() and the response carries X-Blob-* headers.
local config = require "image.config"
local metadata = require "image.metadata"
local apikey = require "image.apikey"
local fs = require "image.fs_ffi"
local upload = require "image.upload"
local rand = require "common.rand"
local logger = require "common.logger"
local pconfig = require "pickup.config"
local ngx = ngx

local _M = {}

local EXTENSIONS = "creation,expiration,termination,checksum"
local READ_CHUNK = 64 * 1024
local SOCKET_TIMEOUT = 60000
local MAX_CHUNK = tonumber(os.getenv("IMAGE_TUS_MAX_CHUNK")) or (64 * 1024 * 1024)
local SESSION_TTL = tonumber(os.getenv("IMAGE_TUS_EXPIRY")) or 86400

local function part_path(id)
    return config.tmp_dir .. "/tus-" .. id .. ".part"
end

local function common_headers()
    ngx.header["Tus-Resumable"] = "1.0.0"
    ngx.header["Cache-Control"] = "no-store"
end

local function finish(status, msg)
    common_headers()
    ngx.status = status
    if msg then
        ngx.header.content_type = "text/plain; charset=utf-8"
        ngx.say(msg)
    end
    return ngx.exit(status)
end

local function blob_headers(hash)
    local blob = metadata.get_image(hash)
    if not blob then return end
    ngx.header["X-Blob-Hash"] = blob.hash
    ngx.header["X-Blob-Kind"] = blob.kind or "other"
    ngx.header["X-Blob-Size"] = tostring(blob.size_bytes)
end

-- Upload-Metadata: "key base64value,key2 base64value2"
function _M.parse_metadata(raw)
    local meta = {}
    for token in string.gmatch(raw or "", "[^,]+") do
        local k, v = token:match("^%s*(%S+)%s*(%S*)%s*$")
        if k then
            local decoded = v ~= "" and (ngx.decode_base64(v) or require("ngx.base64").decode_base64url(v)) or ""
            meta[k:lower()] = decoded
        end
    end
    return meta
end

-- Load a session and check it belongs to the caller (admins see all).
local function owned_session(id, subject)
    local session = metadata.tus_session_get(id)
    if not session then return finish(404, "upload not found") end
    if subject.role ~= "admin" and session.owner ~= subject.hash then
        return finish(404, "upload not found")
    end
    return session
end

-- Turn the finished part file into a blob and answer the final request.
-- `lock` (if any) is released before responding: ngx.exit never returns.
local function complete(id, session, subject, status_on_success, lock)
    local blob, code, status = upload.store(part_path(id), subject)
    if not blob then
        metadata.tus_session_set_state(id, "error")
        if lock then lock:unlock() end
        logger.warn("tus_finalize_failed", { sid = id, error = code })
        return finish(status or 500, code)
    end
    metadata.tus_session_done(id, blob.hash)
    if lock then lock:unlock() end
    ngx.header["Upload-Offset"] = tostring(session.upload_length)
    ngx.header["X-Blob-Hash"] = blob.hash
    ngx.header["X-Blob-Kind"] = blob.kind
    ngx.header["X-Blob-Size"] = tostring(blob.size)
    return finish(status_on_success)
end

function _M.options()
    ngx.header["Tus-Version"] = "1.0.0"
    ngx.header["Tus-Max-Size"] = tostring(pconfig.max_file_bytes)
    ngx.header["Tus-Extension"] = EXTENSIONS
    ngx.header["Tus-Checksum-Algorithm"] = "sha1,sha256"
    return finish(204)
end

-- POST /files/
function _M.create()
    local subject = apikey.require()
    if not require("common.rate_limit").check_upload_limit(subject.hash) then
        return finish(429, "too many uploads, slow down")
    end
    if ngx.var.http_upload_defer_length then
        return finish(400, "Upload-Defer-Length is not supported")
    end
    local length = tonumber(ngx.var.http_upload_length)
    if not length or length < 0 or length ~= math.floor(length) then
        return finish(400, "Upload-Length required")
    end
    if length > pconfig.max_file_bytes then
        return finish(413, "file larger than PICKUP_MAX_FILE_SIZE")
    end
    if not upload.disk_has_room(length) then
        return finish(507, "server storage is full")
    end
    local left = upload.quota_left(subject)
    if left and length > left then
        return finish(413, "upload quota exceeded")
    end

    local id = rand.hex(16)
    local fd, ferr = fs.open_write_excl(part_path(id))
    if not fd then
        logger.err("tus_create_failed", { error = tostring(ferr) })
        return finish(500, "cannot create upload")
    end
    fs.close(fd)

    local now = ngx.time()
    local expires = now + SESSION_TTL
    local ok, err = metadata.tus_session_create(id, length, ngx.var.http_upload_metadata or "",
                                                subject.hash, "", now, expires)
    if not ok then
        fs.unlink(part_path(id))
        logger.err("tus_create_db_failed", { error = tostring(err) })
        return finish(500, "cannot create upload")
    end

    ngx.header["Location"] = "/files/" .. id
    ngx.header["Upload-Expires"] = ngx.http_time(expires)
    if length == 0 then
        local session = metadata.tus_session_get(id)
        return complete(id, session, subject, 201)
    end
    return finish(201)
end

-- HEAD /files/{id}
function _M.head(id)
    local subject = apikey.require()
    local session = owned_session(id, subject)
    if session.state == "error" then return finish(410) end
    ngx.header["Upload-Length"] = tostring(session.upload_length)
    ngx.header["Upload-Expires"] = ngx.http_time(session.expires_at)
    if session.metadata and session.metadata ~= "" then
        ngx.header["Upload-Metadata"] = session.metadata
    end
    if session.state == "done" and session.blob_hash then
        ngx.header["Upload-Offset"] = tostring(session.upload_length)
        blob_headers(session.blob_hash)
    else
        ngx.header["Upload-Offset"] = tostring(session.offset)
    end
    return finish(200)
end

-- PATCH /files/{id}
function _M.patch(id)
    local subject = apikey.require()
    local session = owned_session(id, subject)
    if session.state == "done" then
        ngx.header["Upload-Offset"] = tostring(session.upload_length)
        if session.blob_hash then blob_headers(session.blob_hash) end
        return finish(204)
    end
    if session.state ~= "active" then return finish(410, "upload failed, start again") end
    if session.expires_at <= ngx.time() then return finish(410, "upload expired") end

    if (ngx.var.http_content_type or ""):lower() ~= "application/offset+octet-stream" then
        return finish(415, "Content-Type must be application/offset+octet-stream")
    end
    local body_len = tonumber(ngx.var.http_content_length)
    if not body_len then return finish(411, "Content-Length required") end
    if body_len > MAX_CHUNK then return finish(413, "chunk too large") end

    -- One PATCH per session at a time.
    local lock = require("resty.lock"):new("pickup_locks", { timeout = 0, exptime = 600 })
    if not lock:lock("tus:" .. id) then return finish(409, "upload busy") end
    session = metadata.tus_session_get(id)  -- re-read under the lock

    local offset = tonumber(ngx.var.http_upload_offset)
    if not offset or offset ~= session.offset then
        lock:unlock()
        ngx.header["Upload-Offset"] = tostring(session.offset)
        return finish(409, "offset mismatch")
    end
    if offset + body_len > session.upload_length then
        lock:unlock()
        return finish(400, "chunk exceeds Upload-Length")
    end

    local fd, oerr = fs.open_append(part_path(id))
    if not fd then
        lock:unlock()
        logger.err("tus_open_failed", { sid = id, error = tostring(oerr) })
        return finish(500, "storage error")
    end
    -- A crash between write and DB update can leave extra bytes; the DB
    -- offset is authoritative.
    fs.ftruncate(fd, offset)

    local hasher, alg, expected
    local checksum = ngx.var.http_upload_checksum
    if checksum and checksum ~= "" then
        local a, b64 = checksum:match("^(%w+)%s+(%S+)$")
        expected = b64 and ngx.decode_base64(b64)
        if a == "sha256" then hasher = require("resty.sha256"):new()
        elseif a == "sha1" then hasher = require("resty.sha1"):new() end
        if not hasher or not expected then
            fs.close(fd); lock:unlock()
            return finish(400, "unsupported Upload-Checksum")
        end
        alg = a
    end

    local sock, serr = ngx.req.socket()
    if not sock then
        fs.close(fd); lock:unlock()
        return finish(400, "cannot read body: " .. tostring(serr))
    end
    sock:settimeout(SOCKET_TIMEOUT)

    local remaining, written, werr = body_len, 0, nil
    while remaining > 0 do
        local want = remaining < READ_CHUNK and remaining or READ_CHUNK
        local data, rerr, partial = sock:receive(want)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            local ok, e = fs.write_all(fd, chunk)
            if not ok then werr = e; break end
            if hasher then hasher:update(chunk) end
            written = written + #chunk
            remaining = remaining - #chunk
        end
        if not data then
            logger.info("tus_patch_interrupted", { sid = id, error = rerr, received = written })
            break
        end
    end

    if hasher and remaining == 0 and hasher:final() ~= expected then
        fs.ftruncate(fd, offset)
        fs.close(fd); lock:unlock()
        logger.warn("tus_checksum_mismatch", { sid = id, alg = alg })
        return finish(460, "checksum mismatch")
    end
    if hasher and remaining > 0 then
        -- Partial chunk with a checksum cannot be verified: drop it.
        fs.ftruncate(fd, offset)
        written = 0
    end
    fs.close(fd)

    if werr then
        lock:unlock()
        logger.err("tus_write_failed", { sid = id, error = tostring(werr) })
        return finish(500, "storage error")
    end

    local new_offset = offset + written
    if written > 0 then
        local ok, uerr = metadata.tus_session_advance(id, new_offset)
        if not ok then
            lock:unlock()
            logger.err("tus_offset_failed", { sid = id, error = tostring(uerr) })
            return finish(500, "storage error")
        end
    end

    if new_offset >= session.upload_length then
        return complete(id, session, subject, 204, lock)
    end
    lock:unlock()
    ngx.header["Upload-Offset"] = tostring(new_offset)
    ngx.header["Upload-Expires"] = ngx.http_time(session.expires_at)
    if remaining > 0 then return finish(400, "body incomplete") end
    return finish(204)
end

-- DELETE /files/{id}
function _M.terminate(id)
    local subject = apikey.require()
    owned_session(id, subject)
    fs.unlink(part_path(id))
    metadata.tus_session_delete(id)
    return finish(204)
end

function _M.dispatch()
    local method = ngx.req.get_method()
    if method == "OPTIONS" then return _M.options() end
    local uri = ngx.var.uri or ""
    if uri == "/files/" or uri == "/files" then
        if method == "POST" then return _M.create() end
        return finish(405)
    end
    local id = uri:match("^/files/(%x+)$")
    if not id then return finish(404) end
    if method == "HEAD" then return _M.head(id) end
    if method == "PATCH" then return _M.patch(id) end
    if method == "DELETE" then return _M.terminate(id) end
    return finish(405)
end

return _M
