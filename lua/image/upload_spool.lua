-- Streaming multipart/form-data parser: every file part is written straight
-- to its own temp file (no buffering in the Lua heap), so arbitrarily large
-- uploads use constant memory.
local upload = require "resty.upload"
local fs = require "image.fs_ffi"
local rand = require "common.rand"
local ngx = ngx

local _M = {}

local CHUNK = 64 * 1024

-- Parse `filename="..."` / `filename*=UTF-8''...` from Content-Disposition.
local function part_filename(value)
    local star = value:match("filename%*=[Uu][Tt][Ff]%-8''([^;]+)")
    if star then return ngx.unescape_uri(star) end
    local plain = value:match('filename="([^"]*)"') or value:match("filename=([^;]+)")
    return plain
end

-- Spool all file parts. Returns an array of { path, filename, size } or
-- nil, error_code. Non-file fields are ignored.
function _M.spool_files(tmp_dir, max_file_bytes, max_files)
    local form, err = upload:new(CHUNK)
    if not form then return nil, "bad_multipart: " .. tostring(err) end
    form:set_timeout(60000)  -- slow mobile links

    local files = {}
    local cur          -- current file part { path, fd, size, filename }
    local is_file = false

    local function cleanup()
        if cur and cur.fd then fs.close(cur.fd) end
        for _, f in ipairs(files) do fs.unlink(f.path) end
        if cur then fs.unlink(cur.path) end
    end

    while true do
        local typ, res, rerr = form:read()
        if not typ then cleanup(); return nil, "read_error: " .. tostring(rerr) end

        if typ == "header" then
            local name, value = res[1], res[2]
            if name:lower() == "content-disposition" then
                local fname = part_filename(value)
                is_file = fname ~= nil
                if is_file then
                    if #files >= max_files then cleanup(); return nil, "too_many_files" end
                    local path = tmp_dir .. "/mp-" .. ngx.time() .. "-" .. rand.hex(8) .. ".part"
                    local fd, oerr = fs.open_write_excl(path)
                    if not fd then cleanup(); return nil, "tmp_open_failed: " .. tostring(oerr) end
                    cur = { path = path, fd = fd, size = 0, filename = fname }
                end
            end
        elseif typ == "body" then
            if is_file and cur then
                cur.size = cur.size + #res
                if cur.size > max_file_bytes then cleanup(); return nil, "file_too_large" end
                local ok, werr = fs.write_all(cur.fd, res)
                if not ok then cleanup(); return nil, "write_failed: " .. tostring(werr) end
            end
        elseif typ == "part_end" then
            if is_file and cur then
                fs.close(cur.fd)
                cur.fd = nil
                files[#files + 1] = cur
                cur = nil
            end
            is_file = false
        elseif typ == "eof" then
            break
        end
    end

    if #files == 0 then return nil, "no_file" end
    return files
end

return _M
