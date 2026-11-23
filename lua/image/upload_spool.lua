-- Multipart parsing that streams the file directly to disk instead of
-- accumulating it in Lua memory. We keep a rolling 32-byte "magic" window at
-- the head of the file so format validation can run once the stream is done,
-- and we use the FFI libc helpers in fs_ffi to write without copying through
-- LuaJIT's string interning.
local upload = require "resty.upload"
local fs = require "image.fs_ffi"
local ngx = ngx

local _M = {}

local CHUNK = 64 * 1024
local HEAD_GOAL = 32  -- enough for all magic-byte checks incl. ftyp brand

-- Read the multipart body, writing the first file part to `final_path`
-- atomically (via a temp path + rename). Returns a result table on success:
--   { path, filename, content_type, size, head }
-- where `head` is the first <=32 bytes of the file (magic-bytes validation is
-- the caller's job). On failure returns nil, human-readable error.
function _M.spool_file(final_path, max_bytes)
    local form, err = upload:new(CHUNK)
    if not form then
        return nil, "failed to init upload: " .. tostring(err)
    end
    form:set_timeout(15000)  -- 15s between chunks (slow mobile clients)

    local tmp_path = final_path .. ".uploading." .. ngx.worker.pid()
    local fd, oerr = fs.open_write_excl(tmp_path)
    if not fd then
        return nil, "cannot open temp file: " .. tostring(oerr)
    end

    local total = 0
    local saw_file = false
    local filename
    local content_type
    local head = {}
    local head_len = 0

    local function abort(msg)
        fs.close(fd)
        fs.unlink(tmp_path)
        return nil, msg
    end

    while true do
        local typ, res, rerr = form:read()
        if not typ then return abort("read error: " .. tostring(rerr)) end

        if typ == "header" then
            local name, value = res[1], res[2]
            if name:lower() == "content-disposition" then
                filename = value:match('filename="([^"]*)"')
                if filename then saw_file = true end
            elseif name:lower() == "content-type" then
                content_type = value
            end
        elseif typ == "body" then
            if saw_file then
                -- Keep the first HEAD_GOAL bytes in memory so we can validate
                -- magic bytes without re-reading the file.
                if head_len < HEAD_GOAL then
                    local take = HEAD_GOAL - head_len
                    if #res < take then take = #res end
                    head[#head + 1] = res:sub(1, take)
                    head_len = head_len + take
                end

                total = total + #res
                if total > max_bytes then
                    return abort("file too large")
                end
                local ok, werr = fs.write_all(fd, res)
                if not ok then return abort(werr) end
            end
        elseif typ == "part_end" then
            if saw_file then break end
        elseif typ == "eof" then
            break
        end
    end

    fs.fsync(fd)
    fs.close(fd)

    if total == 0 or head_len < 4 then
        fs.unlink(tmp_path)
        return nil, "no file content"
    end

    -- Atomic publish.
    local ok, rename_err = fs.rename(tmp_path, final_path)
    if not ok then
        fs.unlink(tmp_path)
        return nil, "rename failed: " .. tostring(rename_err)
    end

    return {
        path = final_path,
        filename = filename,
        content_type = content_type,
        size = total,
        head = table.concat(head),
    }
end

return _M
