-- tus 1.0 protocol handler for resumable chunked uploads.
--
-- Implements the core protocol (creation, HEAD, PATCH, DELETE, OPTIONS,
-- expiration) and the checksum extension (sha1/sha256 when available).
-- The creation-with-upload extension is NOT implemented (chunked uploads
-- use creation then PATCH).
--
-- Session state lives in the metadata store (tus_sessions table) and chunk
-- data is appended to local part files. Multi-node P8 extends this with
-- per-node part objects in shared storage for PATCHes hitting non-owning
-- nodes.
--
-- On completion, the assembled file is handed to upload.finalize() which
-- runs the same validation/place/insert pipeline as the multipart path.
local config = require "image.config"
local util = require "image.util"
local storage = require "image.storage"
local metadata = require "image.metadata"
local apikey = require "image.apikey"
local fs = require "image.fs_ffi"
local security = require "image.security"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

local TUS_EXTENSIONS = "creation,creation-with-upload,expiration,termination,checksum"

-- Optional checksum algorithms. resty.sha1 is bundled with OpenResty but
-- may be absent in minimal builds; if it's missing we omit the extension.
local checksum_algorithms = "sha256"
pcall(function()
    require "resty.sha1"
    checksum_algorithms = "sha1,sha256"
end)

-- ---- helpers ----

local function random_id()
    -- 32 hex characters from getrandom (same source as security.csp_nonce).
    return security.csp_nonce()
end

local function respond_405()
    ngx.status = 405; ngx.header.content_type = "text/plain"
    ngx.say("405 Not Allowed"); ngx.exit(405)
end

-- ---- OPTIONS ----
function _M.options()
    ngx.status = 204
    ngx.header["Tus-Resumable"] = "1.0.0"
    ngx.header["Tus-Version"] = "1.0.0"
    ngx.header["Tus-Max-Size"] = tostring(config.max_upload_bytes)
    ngx.header["Tus-Extension"] = TUS_EXTENSIONS
    ngx.header["Tus-Checksum-Algorithm"] = checksum_algorithms
    ngx.exit(204)
end

-- ---- POST /files/ (create) ----
function _M.create()
    local subject = apikey.require()

    local upload_length = tonumber(ngx.var.http_upload_length)
    if not upload_length or upload_length <= 0 then
        -- tus 1.0 requires Upload-Length; creation-with-upload may omit
        -- but we do not support that extension.
        ngx.status = 400; ngx.header.content_type = "text/plain"
        ngx.say("400 Upload-Length required"); ngx.exit(400)
    end
    if upload_length > config.max_upload_bytes then
        ngx.status = 413; ngx.header.content_type = "text/plain"
        ngx.say("413 Payload Too Large"); ngx.exit(413)
    end

    -- Parse Upload-Metadata (comma-separated k=v base64).
    local meta_raw = ngx.var.http_upload_metadata or ""
    local meta = {}
    for token in string.gmatch(meta_raw, "[^,]+") do
        local k, v64 = token:match("^%s*(.-)%s+(.-)%s*$")
        if not k then k = token; v64 = "" end
        k = k:lower()
        -- tus spec: values are base64-encoded; decode them.
        if v64 and v64 ~= "" then
            local ngx_base64 = require "ngx.base64"
            local ok, decoded = pcall(ngx_base64.decode_base64url, v64)
            if ok and decoded then
                meta[k] = decoded
            end
        end
    end

    local session_id = random_id()
    local now = ngx.time()
    local expires = now + tonumber(os.getenv("IMAGE_TUS_EXPIRY")) or 86400

    -- Create the part file path (empty initial file).
    local part_path = config.tmp_dir .. "/tus-" .. session_id .. ".part"
    local fd, ferr = fs.open_write_excl(part_path)
    if not fd then
        logger.err("tus_create_fd_failed", { error = tostring(ferr) })
        ngx.status = 500; ngx.exit(500)
    end
    fs.close(fd)

    local ok, err = metadata.tus_session_create(session_id, upload_length, meta,
                                                  subject.hash, "", now, expires)
    if not ok then
        pcall(fs.unlink, part_path)
        logger.err("tus_create_db_failed", { error = tostring(err) })
        ngx.status = 500; ngx.exit(500)
    end

    ngx.status = 201
    ngx.header["Location"] = "/files/" .. session_id
    ngx.header["Upload-Expires"] = os.date("!%Y-%m-%dT%H:%M:%SZ", expires)
    ngx.exit(201)
end

-- ---- HEAD /files/{id} ----
function _M.head(session_id)
    local session = metadata.tus_session_get(session_id)
    if not session then
        ngx.status = 404; ngx.exit(404)
    end

    -- Auth: owner or admin.
    local subject = apikey.require()
    if subject.role ~= "admin" and session.owner ~= subject.hash then
        ngx.status = 403; ngx.exit(403)
    end

    ngx.header["Upload-Offset"] = tostring(session.offset)
    ngx.header["Upload-Length"] = tostring(session.upload_length)
    if session.metadata and session.metadata ~= "" then
        ngx.header["Upload-Metadata"] = session.metadata
    end
    ngx.header["Upload-Expires"] = os.date("!%Y-%m-%dT%H:%M:%SZ", session.expires_at)
    ngx.header["Cache-Control"] = "no-store"
    ngx.status = 200; ngx.exit(200)
end

-- ---- PATCH /files/{id} ----
function _M.patch(session_id, body)
    local session = metadata.tus_session_get(session_id)
    if not session then
        ngx.status = 404; ngx.exit(404)
    end
    if session.state ~= "active" then
        ngx.status = 410; ngx.exit(410)
    end

    -- Auth: owner or admin.
    local subject = apikey.require()
    if subject.role ~= "admin" and session.owner ~= subject.hash then
        ngx.status = 403; ngx.exit(403)
    end

    -- Validate Content-Type.
    local ct = ngx.var.http_content_type or ""
    if ct:lower() ~= "application/offset+octet-stream" then
        ngx.status = 415; ngx.header.content_type = "text/plain"
        ngx.say("415 unsupported media type (expected application/offset+octet-stream)")
        ngx.exit(415)
    end

    -- Validate Upload-Offset matches session offset.
    local upload_offset = tonumber(ngx.var.http_upload_offset)
    if not upload_offset or upload_offset ~= session.offset then
        ngx.status = 409; ngx.header.content_type = "text/plain"
        ngx.say("409 Conflict: offset mismatch")
        ngx.exit(409)
    end

    -- Limit per-chunk body size.
    local body_bytes = ngx.var.content_length or 0
    local max_chunk = tonumber(os.getenv("IMAGE_TUS_MAX_CHUNK")) or (8 * 1024 * 1024)
    if tonumber(body_bytes) > max_chunk then
        ngx.status = 413; ngx.exit(413)
    end

    -- Append the chunk to the session's part file.
    local part_path = config.tmp_dir .. "/tus-" .. session_id .. ".part"
    local fd, ferr = fs.open_append(part_path)
    if not fd then
        logger.err("tus_patch_open_failed", { sid = session_id, error = tostring(ferr) })
        ngx.status = 500; ngx.exit(500)
    end

    -- Read the body in chunks (resty.upload? No — PATCH with raw body).
    -- For the initial single-node implementation we read the whole body into
    -- Lua (bounded by IMAGE_TUS_MAX_CHUNK).  Multi-node streaming will be
    -- added in P8.
    if not body then
        ngx.req.read_body()
        body = ngx.req.get_body_data()
    end
    if not body or #body == 0 then
        fs.close(fd)
        ngx.status = 204; ngx.exit(204)
    end

    local ok, werr = fs.write_all(fd, body)
    fs.fsync(fd)
    fs.close(fd)

    if not ok then
        logger.err("tus_patch_write_failed", { sid = session_id, error = tostring(werr) })
        ngx.status = 500; ngx.exit(500)
    end

    -- Optional Upload-Checksum verification.
    local checksum_hdr = ngx.var.http_upload_checksum or ""
    if checksum_hdr ~= "" then
        local alg, b64 = checksum_hdr:match("^(%w+)%s+(.+)$")
        if not alg then
            fs.unlink(part_path)
            ngx.status = 460; ngx.header.content_type = "text/plain"
            ngx.say("460 checksum header malformed"); ngx.exit(460)
        end

        local expected
        if alg == "sha1" then
            local sha1 = require "resty.sha1"
            local h = sha1:new(); h:update(body); expected = require "resty.string".to_hex(h:final())
        elseif alg == "sha256" then
            local sha256 = require "resty.sha256"
            local h = sha256:new(); h:update(body); expected = require "resty.string".to_hex(h:final())
        else
            fs.unlink(part_path)
            ngx.status = 460; ngx.exit(460)
        end

        local ngx_b64 = require "ngx.base64"
        local actual = ngx_b64.decode_base64url(b64)
        if actual ~= expected then
            fs.unlink(part_path)
            logger.warn("tus_checksum_mismatch", { sid = session_id, alg = alg })
            ngx.status = 460; ngx.exit(460)
        end
    end

    -- Update the offset in the database.
    local new_offset = session.offset + #body
    local ok, up_err = metadata.tus_session_advance(session_id, new_offset)
    if not ok then
        logger.err("tus_patch_offset_failed", { sid = session_id, error = tostring(up_err) })
        ngx.status = 500; ngx.exit(500)
    end

    -- Complete: hand off to the shared finalize pipeline.
    if new_offset >= session.upload_length then
        metadata.tus_session_set_state(session_id, "completed")
        -- Spawn a background timer for finalize so the PATCH response comes
        -- back quickly. The client polls HEAD for completion status.
        -- Alternatively, finalize synchronously for simplicity:
        local upload = require "image.upload"
        local result = upload.finalize(part_path, session.metadata, subject, nil, true)
        if not result then
            metadata.tus_session_set_state(session_id, "error")
            ngx.header["Upload-Offset"] = tostring(new_offset)
            ngx.status = 204; ngx.exit(204)  -- PATCH response still 204
        end
        metadata.tus_session_set(session_id, result.hash, result.url)
        ngx.header["Upload-Offset"] = tostring(new_offset)
        ngx.header["X-Image-Hash"] = result.hash
        ngx.header["X-Image-URL"] = result.url
        ngx.status = 204; ngx.exit(204)
    end

    ngx.header["Upload-Offset"] = tostring(new_offset)
    ngx.status = 204; ngx.exit(204)
end

-- ---- DELETE /files/{id} (terminate) ----
function _M.terminate(session_id)
    local session = metadata.tus_session_get(session_id)
    if not session then
        ngx.status = 404; ngx.exit(404)
    end

    local subject = apikey.require()
    if subject.role ~= "admin" and session.owner ~= subject.hash then
        ngx.status = 403; ngx.exit(403)
    end

    -- Remove part file.
    local part_path = config.tmp_dir .. "/tus-" .. session_id .. ".part"
    pcall(fs.unlink, part_path)
    metadata.tus_session_delete(session_id)

    ngx.status = 204; ngx.exit(204)
end

-- ---- Request dispatch ----
-- Called from the nginx content_by_lua_block for ~ ^/files/.
function _M.dispatch()
    local uri = ngx.var.uri or ""
    local session_id = uri:match("^/files/(%x+)$")
    local method = ngx.req.get_method()

    if method == "OPTIONS" then
        return _M.options()
    end

    -- POST to the collection endpoint creates a new upload.
    if method == "POST" and uri == "/files/" then
        return _M.create()
    end

    -- All other methods require a session ID.
    if not session_id then
        ngx.status = 404; ngx.exit(404)
    end

    if method == "HEAD"   then return _M.head(session_id) end
    if method == "PATCH"  then return _M.patch(session_id) end
    if method == "DELETE" then return _M.terminate(session_id) end

    respond_405()
end

return _M