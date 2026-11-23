-- Filesystem helpers via LuaJIT FFI (direct libc syscalls).
-- Avoids os.execute / blocking shell and gives precise error codes.
local ffi = require "ffi"
local bit = require "bit"

local C = ffi.C

ffi.cdef[[
typedef long mode_t;
typedef long intptr_t;
typedef unsigned long uintptr_t;
typedef long ssize_t;
typedef unsigned long size_t;

int *__errno_location(void);

int mkdir(const char *pathname, mode_t mode);
int rename(const char *oldpath, const char *newpath);
int unlink(const char *pathname);
int rmdir(const char *pathname);
int access(const char *pathname, int mode);
int chmod(const char *path, mode_t mode);

int open(const char *pathname, int flags, mode_t mode);
int close(int fd);
ssize_t write(int fd, const void *buf, size_t count);
ssize_t read(int fd, void *buf, size_t count);
int fsync(int fd);

void *fopen(const char *path, const char *mode);
int fclose(void *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, void *stream);
size_t fread(void *ptr, size_t size, size_t nmemb, void *stream);
int fseek(void *stream, long offset, int whence);
long ftell(void *stream);
int fileno(void *stream);
int ferror(void *stream);
int fflush(void *stream);

int __xstat(int ver, const char *path, void *buf);

int ftruncate(int fd, long length);
long lseek(int fd, long offset, int whence);

/* struct statvfs (glibc/musl, 64-bit): f_bsize, f_frsize, f_blocks, f_bfree,
   f_bavail, ... -- only the leading fields are read. */
typedef struct { unsigned long long a[16]; } iv_statvfs_t;
int statvfs(const char *path, iv_statvfs_t *s);

typedef struct iv_dir DIR;
struct iv_dirent {
    unsigned long long d_ino;
    long long          d_off;
    unsigned short     d_reclen;
    unsigned char      d_type;
    char               d_name[256];
};
DIR           *opendir(const char *name);
struct iv_dirent *readdir(DIR *dir);
int           closedir(DIR *dir);
]]

-- open() flags for glibc/musl (musl: O_RDONLY=0, O_WRONLY=1, O_RDWR=2, O_CREAT=0100, O_TRUNC=01000, O_EXCL=0200)
local O_WRONLY = 0x0001
local O_CREAT  = 0x0040
local O_TRUNC  = 0x0200
local O_EXCL   = 0x0080
local O_APPEND = 0x0400
local S_IRUSR = 0x100  -- 0o400
local S_IWUSR = 0x080  -- 0o200
local S_IRGRP = 0x020  -- 0o040
local S_IROTH = 0x004  -- 0o004
local DEFAULT_MODE = bit.bor(S_IRUSR, S_IWUSR, S_IRGRP, S_IROTH)  -- 0644

local DIR_MODE = bit.bor(0x1C0, 0x020, 0x002)  -- 0711
local F_OK = 0
local EEXIST = 17
local ENOENT = 2
local SEEK_SET = 0
local SEEK_END = 2

local _M = {}

local function last_errno()
    local loc = C.__errno_location()
    if loc == nil then return 0 end
    return tonumber(loc[0])
end

-- Returns true if path exists and is accessible
function _M.exists(path)
    return C.access(path, F_OK) == 0
end

-- Create a directory; returns true on success or if already exists
function _M.mkdir(path, mode)
    mode = mode or DIR_MODE
    if C.mkdir(path, mode) == 0 then
        return true
    end
    local err = last_errno()
    if err == EEXIST then
        return true
    end
    return nil, "mkdir failed: errno=" .. tostring(err)
end

-- Recursively mkdir -p
function _M.mkdir_p(path)
    if _M.exists(path) then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path then
        local ok, err = _M.mkdir_p(parent)
        if not ok then return nil, err end
    end
    return _M.mkdir(path)
end

-- Atomically rename (for temp -> final)
function _M.rename(old, new)
    if C.rename(old, new) == 0 then return true end
    return nil, "rename failed: errno=" .. tostring(last_errno())
end

function _M.unlink(path)
    if C.unlink(path) == 0 then return true end
    local err = last_errno()
    if err == ENOENT then return true end
    return nil, "unlink failed: errno=" .. tostring(err)
end

-- Write a whole string atomically: write to tmp then rename.
-- Returns final path on success.
function _M.write_file_atomic(final_path, data, tmp_path)
    local mode = bit.bor(O_WRONLY, O_CREAT, O_TRUNC)
    local fd = C.open(tmp_path, mode, DEFAULT_MODE)
    if fd < 0 then
        return nil, "open tmp failed: errno=" .. tostring(last_errno())
    end

    local len = #data
    local ptr = ffi.cast("const char*", data)
    local written = 0
    while written < len do
        local n = C.write(fd, ptr + written, len - written)
        if n <= 0 then
            C.close(fd)
            _M.unlink(tmp_path)
            return nil, "write failed: errno=" .. tostring(last_errno())
        end
        written = written + tonumber(n)
    end
    C.close(fd)

    return _M.rename(tmp_path, final_path)
end

-- Read at most `max_bytes` from the start of a file. Ideal for sniffing
-- magic bytes / headers without touching the rest of a large image.
function _M.read_head(path, max_bytes)
    local fp = C.fopen(path, "rb")
    if fp == nil then return nil, "fopen failed" end
    local want = max_bytes or 64
    local buf = ffi.new("char[?]", want + 1)
    local n = tonumber(C.fread(buf, 1, want, fp))
    C.fclose(fp)
    if n == 0 then return "" end
    return ffi.string(buf, n)
end

-- Read an entire file into a Lua string (via C stdio).
-- Returns nil + message on error; returns "" for empty files.
function _M.read_file(path)
    local fp = C.fopen(path, "rb")
    if fp == nil then
        return nil, "fopen failed: errno=" .. tostring(last_errno())
    end
    if C.fseek(fp, 0, SEEK_END) ~= 0 then
        C.fclose(fp)
        return nil, "fseek failed"
    end
    local size = tonumber(C.ftell(fp))
    C.fseek(fp, 0, SEEK_SET)

    local buf
    if size == 0 then
        C.fclose(fp)
        return ""
    end

    buf = ffi.new("char[?]", size + 1)
    local n = tonumber(C.fread(buf, 1, size, fp))
    C.fclose(fp)
    if n ~= size then
        return nil, "fread short: got " .. tostring(n) .. " of " .. tostring(size)
    end
    return ffi.string(buf, n)
end

-- File size via fseek; returns nil if not found.
function _M.file_size(path)
    local fp = C.fopen(path, "rb")
    if fp == nil then return nil end
    C.fseek(fp, 0, SEEK_END)
    local size = tonumber(C.ftell(fp))
    C.fclose(fp)
    return size
end

-- Iterator over the entries in a directory (non-recursive), yielding names.
-- "." and ".." are skipped. Returns an empty iterator if the directory does
-- not exist or cannot be opened.
function _M.walk_dir(path)
    local dir = C.opendir(path)
    if dir == nil then return function() return nil end end
    return function()
        while true do
            local ent = C.readdir(dir)
            if ent == nil then
                C.closedir(dir)
                return nil
            end
            local name = ffi.string(ent.d_name)
            if name ~= "." and name ~= ".." then
                return name
            end
        end
    end
end

-- Open a file for writing (O_WRONLY|O_CREAT|O_EXCL|O_TRUNC) and return the fd
-- (a Lua number), or nil + error. Used by upload_spool to stream multipart
-- chunks directly to disk without buffering in Lua memory.
function _M.open_write_excl(path, mode)
    local flags = bit.bor(O_WRONLY, O_CREAT, O_EXCL, O_TRUNC)
    local fd = C.open(path, flags, mode or DEFAULT_MODE)
    if fd < 0 then return nil, "open failed: errno=" .. tostring(last_errno()) end
    return tonumber(fd)
end

-- Open an existing file for appending (O_WRONLY|O_CREAT|O_APPEND). Used by
-- tus PATCH to append chunks to the session's part file. Returns fd or nil.
function _M.open_append(path)
    local flags = bit.bor(O_WRONLY, O_CREAT, O_APPEND)
    local fd = C.open(path, flags, DEFAULT_MODE)
    if fd < 0 then return nil, "open append failed: errno=" .. tostring(last_errno()) end
    return tonumber(fd)
end

-- Write an entire Lua string to an open fd. Loops on short writes.
function _M.write_all(fd, data)
    local len = #data
    local ptr = ffi.cast("const char*", data)
    local off = 0
    while off < len do
        local n = tonumber(C.write(fd, ptr + off, len - off))
        if n <= 0 then return nil, "write failed: errno=" .. tostring(last_errno()) end
        off = off + n
    end
    return true
end

function _M.close(fd)
    return C.close(fd) == 0
end

function _M.fsync(fd)
    return C.fsync(fd) == 0
end

-- Open a file read-only; returns fd or nil, err.
function _M.open_read(path)
    local fd = C.open(path, 0, 0)
    if fd < 0 then return nil, "open failed: errno=" .. tostring(last_errno()) end
    return tonumber(fd)
end

-- Read up to `n` bytes from fd into a Lua string. Returns "" at EOF,
-- or nil, err on failure. `buf` (char[n]) may be passed to avoid
-- reallocating per call.
function _M.read_fd(fd, n, buf)
    buf = buf or ffi.new("char[?]", n)
    local got = tonumber(C.read(fd, buf, n))
    if got < 0 then return nil, "read failed: errno=" .. tostring(last_errno()) end
    if got == 0 then return "" end
    return ffi.string(buf, got)
end

-- Truncate an open file to `size` bytes and move the offset there.
function _M.ftruncate(fd, size)
    if C.ftruncate(fd, size) ~= 0 then
        return nil, "ftruncate failed: errno=" .. tostring(last_errno())
    end
    C.lseek(fd, size, SEEK_SET)
    return true
end

-- Filesystem capacity for the filesystem holding `path`:
-- returns total_bytes, available_bytes (for unprivileged users) or nil.
function _M.disk_stats(path)
    local buf = ffi.new("iv_statvfs_t")
    if C.statvfs(path, buf) ~= 0 then return nil end
    local frsize = tonumber(buf.a[1])
    if not frsize or frsize == 0 then frsize = tonumber(buf.a[0]) end
    return tonumber(buf.a[2]) * frsize, tonumber(buf.a[4]) * frsize
end

-- Constants exposed for callers
_M.EEXIST = EEXIST
_M.ENOENT = ENOENT
_M.DEFAULT_MODE = DEFAULT_MODE

return _M
