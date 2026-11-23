-- SQLite3 binding via LuaJIT FFI.
-- Thin, ergonomic wrapper over the subset of the C API used for image metadata.
--
-- Usage:
--   local db = sqlite.open("/data/image.db")
--   db:exec("CREATE TABLE IF NOT EXISTS ...")
--   local stmt = db:prepare("INSERT INTO t(a,b) VALUES(?,?)")
--   stmt:bind(1, "x"):bind(2, 5):step()
--   stmt:finalize()
--   for row in db:query("SELECT id, hash FROM images") do ... end
--   db:close()

local ffi = require "ffi"
local bit = require "bit"

-- Opaque handles and the subset of the API we need.
ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
typedef unsigned long long sqlite3_uint64;
typedef void (*sqlite3_destructor_type)(void*);
typedef int (*sqlite3_callback)(void*, int, char**, char**);

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                       sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *pStmt);
int sqlite3_finalize(sqlite3_stmt *pStmt);
int sqlite3_reset(sqlite3_stmt *pStmt);
int sqlite3_clear_bindings(sqlite3_stmt *pStmt);

int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int n, sqlite3_destructor_type);
int sqlite3_bind_blob(sqlite3_stmt*, int, const void*, int n, sqlite3_destructor_type);
int sqlite3_bind_int64(sqlite3_stmt*, int, sqlite3_int64);
int sqlite3_bind_int(sqlite3_stmt*, int, int);
int sqlite3_bind_null(sqlite3_stmt*, int);

int sqlite3_column_count(sqlite3_stmt *pStmt);
int sqlite3_column_type(sqlite3_stmt*, int iCol);
const unsigned char *sqlite3_column_text(sqlite3_stmt*, int iCol);
const void *sqlite3_column_blob(sqlite3_stmt*, int iCol);
int sqlite3_column_bytes(sqlite3_stmt*, int iCol);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt*, int iCol);
const char *sqlite3_column_name(sqlite3_stmt*, int iCol);

int sqlite3_exec(sqlite3*, const char *sql, sqlite3_callback, void *, char **errmsg);
void sqlite3_free(void *ptr);
const char *sqlite3_errmsg(sqlite3 *db);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db);
int sqlite3_changes(sqlite3 *db);
]]

local sqlite = ffi.load("sqlite3")

-- Result codes
local OK            = 0
local ERROR         = 1
local BUSY          = 5
local ROW           = 100
local DONE          = 101

-- open flags
local SQLITE_OPEN_READWRITE   = 0x00000002
local SQLITE_OPEN_CREATE      = 0x00000004
local SQLITE_OPEN_FULLMUTEX   = 0x00010000
local SQLITE_OPEN_NOMUTEX     = 0x00008000

-- column types
local SQLITE_INTEGER = 1
local SQLITE_FLOAT   = 2
local SQLITE_TEXT    = 3
local SQLITE_BLOB    = 4
local SQLITE_NULL    = 5

-- SQLITE_TRANSIENT: special destructor meaning SQLite copies the data immediately.
-- The value is ((sqlite3_destructor_type)-1).
local SQLITE_TRANSIENT = ffi.cast("sqlite3_destructor_type", -1)

local _M = {}
_M.OK, _M.ERROR, _M.BUSY, _M.ROW, _M.DONE = OK, ERROR, BUSY, ROW, DONE

local function errmsg(db)
    local p = sqlite.sqlite3_errmsg(db)
    if p == nil then return "unknown sqlite error" end
    return ffi.string(p)
end

local function check(db, rc, context)
    if rc ~= OK and rc ~= ROW and rc ~= DONE and rc ~= BUSY then
        error(("sqlite %s: %s (rc=%d)"):format(context or "error", errmsg(db), rc), 2)
    end
    return rc
end

----------------- Statement -----------------

local stmt_mt = {}
stmt_mt.__index = stmt_mt

function stmt_mt:bind(idx, value)
    local st = self._st
    if value == nil then
        check(self._db, sqlite.sqlite3_bind_null(st, idx), "bind_null")
    elseif type(value) == "number" then
        -- integer if it is a whole number within safe JS/SQL int64 range
        local s = tostring(value)
        if value == math.floor(value) and math.abs(value) < 9007199254740992 then
            check(self._db, sqlite.sqlite3_bind_int64(st, idx, value), "bind_int64")
        else
            check(self._db, sqlite.sqlite3_bind_text(st, idx, s, #s, SQLITE_TRANSIENT), "bind_text")
        end
    elseif type(value) == "boolean" then
        check(self._db, sqlite.sqlite3_bind_int(st, idx, value and 1 or 0), "bind_int")
    elseif type(value) == "string" then
        check(self._db, sqlite.sqlite3_bind_text(st, idx, value, #value, SQLITE_TRANSIENT), "bind_text")
    elseif type(value) == "cdata" then
        -- assume blob (a char[?]) — callers can use :bind_blob explicitly too
        check(self._db, sqlite.sqlite3_bind_blob(st, idx, value, ffi.sizeof(value), SQLITE_TRANSIENT), "bind_blob")
    else
        error("cannot bind value of type " .. type(value), 2)
    end
    return self
end

function stmt_mt:bind_text(idx, s)
    check(self._db, sqlite.sqlite3_bind_text(self._st, idx, s, #s, SQLITE_TRANSIENT), "bind_text")
    return self
end

function stmt_mt:bind_int(idx, n)
    check(self._db, sqlite.sqlite3_bind_int64(self._st, idx, n), "bind_int")
    return self
end

function stmt_mt:bind_blob(idx, data, len)
    check(self._db, sqlite.sqlite3_bind_blob(self._st, idx, data, len, SQLITE_TRANSIENT), "bind_blob")
    return self
end

function stmt_mt:step()
    return sqlite.sqlite3_step(self._st)
end

function stmt_mt:exists()
    return self:step() == ROW
end

function stmt_mt:reset()
    sqlite.sqlite3_reset(self._st)
    sqlite.sqlite3_clear_bindings(self._st)
    return self
end

function stmt_mt:finalize()
    if self._st ~= nil then
        sqlite.sqlite3_finalize(self._st)
        self._st = nil
    end
end

-- Collect column values for the current row as an array and a name->value map.
function stmt_mt:row()
    local st = self._st
    local n = sqlite.sqlite3_column_count(st)
    local arr = {}
    local map = {}
    for i = 0, n - 1 do
        local coltype = sqlite.sqlite3_column_type(st, i)
        local name = ffi.string(sqlite.sqlite3_column_name(st, i))
        local v
        if coltype == SQLITE_NULL then
            v = nil
        elseif coltype == SQLITE_INTEGER then
            v = tonumber(sqlite.sqlite3_column_int64(st, i))
        elseif coltype == SQLITE_TEXT then
            local p = sqlite.sqlite3_column_text(st, i)
            if p == nil then
                v = nil
            else
                local len = sqlite.sqlite3_column_bytes(st, i)
                v = ffi.string(p, len)
            end
        elseif coltype == SQLITE_BLOB then
            local p = sqlite.sqlite3_column_blob(st, i)
            local len = sqlite.sqlite3_column_bytes(st, i)
            v = (p ~= nil) and ffi.string(p, len) or nil
        else -- SQLITE_FLOAT or anything else: return as text
            local p = sqlite.sqlite3_column_text(st, i)
            v = (p ~= nil) and ffi.string(p) or nil
        end
        arr[i + 1] = v
        map[name] = v
    end
    return arr, map
end

----------------- Database -----------------

local db_mt = {}
db_mt.__index = db_mt

function _M.open(path)
    local handle = ffi.new("sqlite3*[1]")
    local flags = bit.bor(SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE, SQLITE_OPEN_FULLMUTEX)
    local rc = sqlite.sqlite3_open_v2(path, handle, flags, nil)
    local db = handle[0]
    if rc ~= OK then
        local msg = (db ~= nil) and errmsg(db) or "open failed"
        if db ~= nil then sqlite.sqlite3_close_v2(db) end
        error("sqlite open '" .. path .. "': " .. msg .. " (rc=" .. rc .. ")", 2)
    end

    -- Pragmas suitable for a low-traffic local metadata store.
    local self = setmetatable({ _db = db, _path = path }, db_mt)
    self:exec("PRAGMA journal_mode=WAL;")
    self:exec("PRAGMA synchronous=NORMAL;")
    self:exec("PRAGMA foreign_keys=ON;")
    self:exec("PRAGMA busy_timeout=5000;")
    return self
end

function db_mt:prepare(sql)
    local handle = ffi.new("sqlite3_stmt*[1]")
    local rc = sqlite.sqlite3_prepare_v2(self._db, sql, #sql, handle, nil)
    if rc ~= OK then
        error("prepare failed: " .. errmsg(self._db) .. " | SQL: " .. sql, 2)
    end
    return setmetatable({ _st = handle[0], _db = self._db }, stmt_mt)
end

-- Execute SQL that does not return rows (DDL/DML).
function db_mt:exec(sql)
    local err = ffi.new("char*[1]")
    local rc = sqlite.sqlite3_exec(self._db, sql, nil, nil, err)
    if rc ~= OK then
        local msg = (err[0] ~= nil) and ffi.string(err[0]) or errmsg(self._db)
        if err[0] ~= nil then sqlite.sqlite3_free(err[0]) end
        error("exec failed: " .. msg .. " | SQL: " .. sql, 2)
    end
    return self
end

-- Run a statement once with bound parameters.
function db_mt:run(sql, ...)
    local st = self:prepare(sql)
    local n = select("#", ...)
    for i = 1, n do
        st:bind(i, select(i, ...))
    end
    local rc = st:step()
    st:finalize()
    return rc
end

-- Iterator over result rows:
--   for arr, row in db:query("SELECT ...", a, b) do ... end
function db_mt:query(sql, ...)
    local st = self:prepare(sql)
    local n = select("#", ...)
    for i = 1, n do
        st:bind(i, select(i, ...))
    end
    return function()
        local rc = st:step()
        if rc == ROW then
            return st:row()
        end
        if rc ~= DONE then
            st:finalize()
            error("query step failed: " .. errmsg(self._db), 2)
        end
        st:finalize()
        return nil
    end
end

-- Return first row (as name->value map) or nil.
function db_mt:query_row(sql, ...)
    local st = self:prepare(sql)
    local n = select("#", ...)
    for i = 1, n do st:bind(i, select(i, ...)) end
    local rc = st:step()
    local row
    if rc == ROW then
        _, row = st:row()
    elseif rc ~= DONE and rc ~= OK then
        st:finalize()
        error("query_row failed: " .. errmsg(self._db), 2)
    end
    st:finalize()
    return row
end

function db_mt:last_insert_rowid()
    return tonumber(sqlite.sqlite3_last_insert_rowid(self._db))
end

function db_mt:changes()
    return sqlite.sqlite3_changes(self._db)
end

function db_mt:close()
    if self._db ~= nil then
        sqlite.sqlite3_close_v2(self._db)
        self._db = nil
    end
end

function db_mt:errmsg()
    return errmsg(self._db)
end

return _M
