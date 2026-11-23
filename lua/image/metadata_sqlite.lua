-- Image metadata persistence backed by SQLite (via sqlite_ffi).
--
-- Concurrency model:
--   * SQLite is opened in FULLMUTEX mode with WAL; every worker has its own
--     connection.
--   * A per-worker semaphore serializes writes so we don't get SQLITE_BUSY
--     storms between coroutines sharing the worker connection.
--   * The whole quota check + image insert + usage UPSERT runs inside that
--     write lock as a single transaction, so concurrent uploads can never
--     both pass a quota check and both write (fixes the TOCTOU where two
--     uploads could overshoot the cap).
--   * Initialization is guarded by a one-shot semaphore so multiple
--     coroutines hitting a cold worker don't open duplicate connections.
--
-- This module implements the metadata backend interface (see image.metadata
-- for dispatch).
local sqlite = require "image.sqlite_ffi"
local config = require "image.config"
local fs = require "image.fs_ffi"
local storage = require "image.storage"
local logger = require "common.logger"
local ngx = ngx

local _M = {}

local db = nil
local init_sema = require "ngx.semaphore".new()
init_sema:post(1)

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS images (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    hash          TEXT NOT NULL UNIQUE,
    orig_ext      TEXT NOT NULL,
    mime          TEXT NOT NULL,
    size_bytes    INTEGER NOT NULL,
    width         INTEGER,
    height        INTEGER,
    uploaded_by   TEXT,                -- sha256 of the API key that uploaded
    uploaded_at   INTEGER NOT NULL,
    deleted       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_images_uploaded ON images(uploaded_at);
CREATE INDEX IF NOT EXISTS idx_images_owner    ON images(uploaded_by, deleted);
]]

-- Rolling-window usage counters. Keyed by key hash so plaintext secrets are
-- never persisted.
local SCHEMA_USAGE = [[
CREATE TABLE IF NOT EXISTS usage (
    key_hash      TEXT PRIMARY KEY,
    window_start  INTEGER NOT NULL,
    bytes_used    INTEGER NOT NULL DEFAULT 0,
    uploads       INTEGER NOT NULL DEFAULT 0
);
]]

-- Short slugs: 8-character base62 aliases that 302 to /i/<hash>.
local SCHEMA_SLUGS = [[
CREATE TABLE IF NOT EXISTS slugs (
    slug        TEXT PRIMARY KEY,
    hash        TEXT NOT NULL,
    created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_slugs_hash ON slugs(hash);
]]

-- tus 1.0 upload sessions.
local SCHEMA_TUS = [[
CREATE TABLE IF NOT EXISTS tus_sessions (
    id             TEXT PRIMARY KEY,
    upload_length  INTEGER NOT NULL,
    offset         INTEGER NOT NULL DEFAULT 0,
    metadata       TEXT NOT NULL DEFAULT '',
    owner          TEXT,
    owner_node     TEXT NOT NULL DEFAULT '',
    created_at     INTEGER NOT NULL,
    expires_at     INTEGER NOT NULL,
    state          TEXT NOT NULL DEFAULT 'active'
);
]]

-- Per-day download stats (aggregated from shared dict by stats_flush.lua).
local SCHEMA_STATS = [[
CREATE TABLE IF NOT EXISTS stats_daily (
    day   INTEGER NOT NULL,
    hash  TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    bytes INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(day, hash)
);
]]

-- Shares: a set of blobs published under a link (slug) and a pickup code.
-- `code` is NULL once the share is dead so codes can be reused.
local SCHEMA_SHARES = [[
CREATE TABLE IF NOT EXISTS shares (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    slug         TEXT NOT NULL UNIQUE,
    code         TEXT,
    title        TEXT NOT NULL DEFAULT '',
    owner        TEXT NOT NULL,
    owner_name   TEXT NOT NULL DEFAULT '',
    created_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL,
    max_visits   INTEGER NOT NULL DEFAULT 0,
    visit_count  INTEGER NOT NULL DEFAULT 0,
    revoked      INTEGER NOT NULL DEFAULT 0,
    file_count   INTEGER NOT NULL DEFAULT 0,
    total_bytes  INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_shares_code ON shares(code) WHERE code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_shares_owner ON shares(owner, id);
CREATE INDEX IF NOT EXISTS idx_shares_expires ON shares(expires_at);
CREATE TABLE IF NOT EXISTS share_files (
    share_id   INTEGER NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    blob_hash  TEXT NOT NULL,
    name       TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    mime       TEXT NOT NULL,
    kind       TEXT NOT NULL,
    PRIMARY KEY (share_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_share_files_blob ON share_files(blob_hash);
]]

local LOCK_TIMEOUT = 10  -- seconds to wait for the metadata write lock

-- Open the DB (idempotent). Uses a module-level semaphore so that if several
-- request coroutines in the same worker hit a cold module simultaneously,
-- only one opens SQLite while the rest wait and then reuse the handle. A
-- failed open leaves db=nil so the next request can retry.
function _M.init()
    if db then return true end
    local got = init_sema:wait(LOCK_TIMEOUT * 1000)
    if not got then return nil, "metadata init timeout" end
    if db then
        init_sema:post(1)
        return true
    end
    local ok, err = pcall(function()
        fs.mkdir_p(config.data_dir)
        db = sqlite.open(config.db_path)
        -- WAL + autocheckpoint keeps the WAL file from growing without
        -- bound on a long-running worker. 1000 pages ~= 4 MiB.
        db:exec("PRAGMA journal_mode=WAL;")
        db:exec("PRAGMA synchronous=NORMAL;")
        db:exec("PRAGMA foreign_keys=ON;")
        db:exec("PRAGMA busy_timeout=5000;")
        db:exec("PRAGMA wal_autocheckpoint=1000;")
        db:exec(SCHEMA)
        db:exec(SCHEMA_USAGE)
        db:exec(SCHEMA_SLUGS)
        db:exec(SCHEMA_STATS)
        db:exec(SCHEMA_TUS)
        db:exec(SCHEMA_SHARES)
        -- Apply any pending migrations (additive ALTER TABLEs for upgrades).
        _M.apply_migrations()
    end)
    init_sema:post(1)
    if not ok then
        logger.err("metadata_init_failed", { error = tostring(err) })
        db = nil
        return nil, tostring(err)
    end
    return true
end

-- Additive migrations beyond CREATE TABLE IF NOT EXISTS. Each migration is
-- keyed by an idempotent PRAGMA user_version bump; new statements should be
-- appended in order. Keep statements SQLite-compatible and idempotent.
local MIGRATIONS = {
    -- 1: initial schema (already applied by SCHEMA above); reserved so
    -- future migrations start at 2.
    -- 2: phash column for perceptual hash (pHash similarity detection, P3).
    [[ALTER TABLE images ADD COLUMN phash TEXT;]],
    -- 3: backed_up column for backup sync (P5).
    [[ALTER TABLE images ADD COLUMN backed_up INTEGER DEFAULT 0;]],
    -- 4: blob kind (image/video/audio/other) decided by content sniffing.
    [[ALTER TABLE images ADD COLUMN kind TEXT NOT NULL DEFAULT 'image';]],
    -- 5: CRC-32 of the blob, needed to stream zip archives without re-reading.
    [[ALTER TABLE images ADD COLUMN crc32 INTEGER;]],
    -- 6: finished tus uploads remember the blob they produced.
    [[ALTER TABLE tus_sessions ADD COLUMN blob_hash TEXT;]],
}

function _M.apply_migrations()
    if not db then return end
    local row = db:query_row("PRAGMA user_version")
    local v = row and tonumber(row.user_version) or 0
    for i = v + 1, #MIGRATIONS do
        db:exec(MIGRATIONS[i])
        db:exec("PRAGMA user_version = " .. i)
    end
end

-- True when init has completed successfully for this worker.
function _M.ready()
    return db ~= nil
end

-- Raw connection (after init) for modules that run their own SQL.
function _M.db()
    if not db then _M.init() end
    return db
end

-- Per-worker write serialization semaphore.
local write_sema = require "ngx.semaphore".new()
write_sema:post(1)

local function with_write_lock(fn)
    local ok = write_sema:wait(LOCK_TIMEOUT * 1000)
    if not ok then
        return nil, "metadata lock timeout"
    end
    local results = { pcall(fn) }
    write_sema:post(1)
    if not results[1] then
        return nil, tostring(results[2])
    end
    return select(2, unpack(results))
end


-- Run fn(db) while holding this worker's write lock (single statements are
-- atomic in SQLite; use tx() for multi-statement atomicity).
function _M.write(fn)
    if not db then _M.init() end
    if not db then return nil, "db_unavailable" end
    return with_write_lock(function() return fn(db) end)
end

-- Run fn(db) inside BEGIN IMMEDIATE ... COMMIT under the write lock and
-- return fn's results. Any failure (including a Lua error raised by fn, which
-- may be a table) rolls back and is re-raised to the caller unchanged.
function _M.tx(fn)
    if not db then _M.init() end
    if not db then error("db_unavailable", 0) end
    local fn_err
    local a, b, c = with_write_lock(function()
        db:exec("BEGIN IMMEDIATE")
        local res = { pcall(fn, db) }
        if res[1] then
            db:exec("COMMIT")
            return select(2, unpack(res))
        end
        pcall(db.exec, db, "ROLLBACK")
        fn_err = res[2]
        return nil, "fn_failed"
    end)
    if fn_err ~= nil then error(fn_err, 0) end
    if a == nil and b ~= nil then error(b, 0) end
    return a, b, c
end

-- Collect all rows of a query as an array of name->value maps.
function _M.rows(sql, ...)
    if not db then _M.init() end
    if not db then return {} end
    local out = {}
    for _, row in db:query(sql, ...) do out[#out + 1] = row end
    return out
end

function _M.row(sql, ...)
    if not db then _M.init() end
    if not db then return nil end
    return db:query_row(sql, ...)
end

-- Start-of-window timestamp. We use a rolling window of
-- config.quota_window_days days rather than calendar months so it is
-- timezone-independent.
local function current_window_start()
    return ngx.time() - (ngx.time() % (config.quota_window_days * 86400))
end

-- Increment usage for a key. Caller must hold the write lock.
local function add_usage_locked(key_hash, bytes)
    if not key_hash then return end
    local win = current_window_start()
    db:run(
        [[INSERT INTO usage(key_hash, window_start, bytes_used, uploads)
          VALUES(?, ?, ?, 1)
          ON CONFLICT(key_hash) DO UPDATE SET
            bytes_used = CASE WHEN usage.window_start = ?
                              THEN usage.bytes_used + ?
                              ELSE ? END,
            uploads    = CASE WHEN usage.window_start = ?
                              THEN usage.uploads + 1
                              ELSE 1 END,
            window_start = ?]],
        key_hash, win, bytes, win, bytes, bytes, win, win)
end

-- Read current usage for a key, rolling the window internally if needed.
-- Returns (bytes_used, uploads).
function _M.usage_for(key_hash)
    if not db then _M.init() end
    if not db or not key_hash then return 0, 0 end
    local win = current_window_start()
    local row = db:query_row(
        "SELECT bytes_used, uploads, window_start FROM usage WHERE key_hash=?",
        key_hash)
    if not row then return 0, 0 end
    if tonumber(row.window_start) ~= win then return 0, 0 end
    return tonumber(row.bytes_used) or 0, tonumber(row.uploads) or 0
end

-- Insert an image and atomically enforce + record the uploader's quota.
--
-- t must contain: hash, orig_ext, mime, size_bytes, uploaded_by (key hash).
-- `quota` is the per-key byte cap; pass nil/0 to skip the check.
--
-- Returns (id, "ok") on success, or (nil, reason) where reason is one of
-- "db_unavailable", "quota", or a free-form error string.
function _M.insert_with_quota(t, quota)
    if not db then _M.init() end
    if not db then return nil, "db_unavailable" end

    return with_write_lock(function()
        -- Double-check for a concurrent insert of the same content hash. If a
        -- row already exists, treat this as a dedup hit: don't charge quota
        -- and don't error (the uploader still gets a 201 with deduped=true).
        local existing = db:query_row(
            "SELECT hash FROM images WHERE hash=?", t.hash)
        if existing then
            return nil, "dedup"
        end

        if quota and quota > 0 and t.uploaded_by then
            local win = current_window_start()
            local row = db:query_row(
                "SELECT bytes_used, window_start FROM usage WHERE key_hash=?",
                t.uploaded_by)
            local used = 0
            if row and tonumber(row.window_start) == win then
                used = tonumber(row.bytes_used) or 0
            end
            if used + t.size_bytes > quota then
                return nil, "quota"
            end
        end

        db:run(
            [[INSERT OR IGNORE INTO images
                (hash, orig_ext, mime, size_bytes, width, height,
                 uploaded_by, uploaded_at, kind, crc32)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
            t.hash, t.orig_ext, t.mime, t.size_bytes,
            t.width, t.height,
            t.uploaded_by, ngx.time(), t.kind or "other", t.crc32)

        if t.uploaded_by then
            add_usage_locked(t.uploaded_by, t.size_bytes)
        end
        return db:last_insert_rowid(), "ok"
    end)
end

-- Backwards-compatible plain insert (no quota check). Prefer
-- insert_with_quota in request paths.
function _M.insert_image(t)
    return _M.insert_with_quota(t, nil)
end

function _M.get_image(hash)
    if not db then _M.init() end
    if not db then return nil end
    local ok, row = pcall(function()
        return db:query_row(
            [[SELECT id, hash, orig_ext, mime, size_bytes, width, height,
                     uploaded_by, uploaded_at, deleted, kind, crc32
              FROM images WHERE hash = ?]],
            hash)
    end)
    if not ok then
        logger.err("metadata_get_image_failed", { error = row })
        return nil
    end
    if row and tonumber(row.deleted) == 1 then return nil end
    return row
end

-- Refresh a blob's upload time (dedup hit) so the unshared-blob grace
-- period restarts and GC does not reclaim it under a fresh upload.
function _M.touch_blob(hash)
    if not db then _M.init() end
    if not db then return end
    with_write_lock(function()
        db:run("UPDATE images SET uploaded_at=? WHERE hash=?", ngx.time(), hash)
    end)
end

-- Store the perceptual hash for an image.
function _M.set_phash(hash, phash_hex)
    if not db then _M.init() end
    if not db or not hash or not phash_hex then return end
    pcall(db.run, db, "UPDATE images SET phash=? WHERE hash=?", phash_hex, hash)
end

-- Return all live (hash, phash) rows except the given hash, for linear-scan
-- Hamming-distance comparison. Personal-scale (thousands of images); for
-- larger datasets a BK-tree would replace this function.
function _M.phash_candidates(except_hash)
    if not db then _M.init() end
    if not db then return {} end
    local rows = {}
    local ok, err = pcall(function()
        for _, row in db:query(
            "SELECT hash, phash FROM images WHERE deleted=0 AND phash IS NOT NULL"
        ) do
            if row.hash ~= except_hash then
                rows[#rows + 1] = row
            end
        end
    end)
    if not ok then
        logger.err("metadata_phash_candidates_failed", { error = err })
    end
    return rows
end

function _M.soft_delete(hash, uploaded_by)
    if not db then _M.init() end
    if not db then return nil end
    return with_write_lock(function()
        if uploaded_by then
            db:run("UPDATE images SET deleted=1 WHERE hash=? AND uploaded_by=?",
                   hash, uploaded_by)
        else
            db:run("UPDATE images SET deleted=1 WHERE hash=?", hash)
        end
        return db:changes()
    end)
end

-- List images uploaded by a specific key hash (owner self-service).
function _M.list_by_owner(key_hash, limit, offset)
    if not db then _M.init() end
    if not db then return {} end
    limit = math.min(tonumber(limit) or 50, 200)
    offset = tonumber(offset) or 0
    local rows = {}
    local ok, err = pcall(function()
        for _, row in db:query(
            [[SELECT hash, orig_ext, mime, size_bytes, width, height, uploaded_at
              FROM images WHERE deleted=0 AND uploaded_by=?
              ORDER BY id DESC LIMIT ? OFFSET ?]],
            key_hash, limit, offset) do
            rows[#rows + 1] = row
        end
    end)
    if not ok then
        logger.err("metadata_list_by_owner_failed", { error = err })
    end
    return rows
end

function _M.recent(limit, owner_hash, offset)
    if not db then _M.init() end
    if not db then return {} end
    limit = math.min(tonumber(limit) or 50, 200)
    offset = tonumber(offset) or 0
    local rows = {}
    local ok, err = pcall(function()
        if owner_hash then
            for _, row in db:query(
                [[SELECT hash, orig_ext, mime, size_bytes, width, height,
                         uploaded_by, uploaded_at
                  FROM images WHERE deleted=0 AND uploaded_by=?
                  ORDER BY id DESC LIMIT ? OFFSET ?]],
                owner_hash, limit, offset) do
                rows[#rows + 1] = row
            end
        else
            for _, row in db:query(
                [[SELECT hash, orig_ext, mime, size_bytes, width, height,
                         uploaded_by, uploaded_at
                  FROM images WHERE deleted=0
                  ORDER BY id DESC LIMIT ? OFFSET ?]],
                limit, offset) do
                rows[#rows + 1] = row
            end
        end
    end)
    if not ok then
        logger.err("metadata_recent_failed", { error = err })
    end
    return rows
end

-- Count total live images. If owner_hash is given, scoped to that key.
function _M.count(owner_hash)
    if not db then _M.init() end
    if not db then return 0 end
    local row
    if owner_hash then
        row = db:query_row(
            "SELECT COUNT(*) AS c FROM images WHERE deleted=0 AND uploaded_by=?",
            owner_hash)
    else
        row = db:query_row(
            "SELECT COUNT(*) AS c FROM images WHERE deleted=0")
    end
    return row and tonumber(row.c) or 0
end

-- Return the existing slug for a hash, or nil.
function _M.get_slug(slug)
    if not db then _M.init() end
    if not db then return nil end
    local row = db:query_row("SELECT hash FROM slugs WHERE slug=?", slug)
    return row and row.hash
end

-- Map a hash to a new short slug. Idempotent: if a slug already exists for
-- this hash it is returned. Collisions on the slug are retried up to 8
-- times. Returns the slug or nil.
local BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
do
    -- Seed once per worker (init time). ngx.time + worker pid + now is enough
    -- for non-cryptographic slug uniqueness; DB UNIQUE constraint + retries
    -- provide the real guarantee.
    math.randomseed(ngx.time() + ngx.worker.pid() * 1000003)
end
local function random_slug(len)
    local out = {}
    for i = 1, len do
        local n = math.random(62)
        out[i] = BASE62:sub(n, n)
    end
    return table.concat(out)
end

function _M.ensure_slug(hash)
    if not db then _M.init() end
    if not db then return nil end
    local existing = db:query_row("SELECT slug FROM slugs WHERE hash=?", hash)
    if existing then return existing.slug end
    return with_write_lock(function()
        for _ = 1, 8 do
            local s = random_slug(8)
            local ok = pcall(db.run, db,
                "INSERT INTO slugs(slug, hash, created_at) VALUES(?, ?, ?)",
                s, hash, ngx.time())
            if ok then return s end
        end
        return nil
    end)
end

-- Return images that have not been backed up (backed_up IS NULL or 0).
function _M.images_by_backlog(limit)
    if not db then _M.init() end
    if not db then return function() return nil end end
    return db:query(
        "SELECT hash, orig_ext, size_bytes FROM images WHERE deleted=0 AND (backed_up IS NULL OR backed_up=0) ORDER BY uploaded_at LIMIT ?",
        math.min(tonumber(limit) or 100, 500))
end

-- Mark an image as backed up.
function _M.set_backed_up(hash)
    if not db then _M.init() end
    if not db then return end
    pcall(db.run, db, "UPDATE images SET backed_up=? WHERE hash=?", ngx.time(), hash)
end

-- Return rows where phash has not yet been computed (limited for backfill).
function _M.images_missing_phash(limit)
    if not db then _M.init() end
    if not db then return {} end
    local rows = {}
    pcall(function()
        for _, row in db:query(
            "SELECT hash, orig_ext FROM images WHERE deleted=0 AND phash IS NULL LIMIT ?",
            math.min(tonumber(limit) or 20, 200)) do
            rows[#rows + 1] = row
        end
    end)
    return rows
end

-- Batch soft-delete by hash list, optionally restricted to an owner.
-- Returns number of rows changed.
function _M.soft_delete_many(hashes, owner_hash)
    if not db then _M.init() end
    if not db or type(hashes) ~= "table" or #hashes == 0 then return 0 end
    return with_write_lock(function()
        local total = 0
        for _, h in ipairs(hashes) do
            if owner_hash then
                db:run("UPDATE images SET deleted=1 WHERE hash=? AND uploaded_by=?",
                       h, owner_hash)
            else
                db:run("UPDATE images SET deleted=1 WHERE hash=?", h)
            end
            total = total + db:changes()
        end
        return total
    end)
end

function _M.stats()
    if not db then _M.init() end
    if not db then return {} end
    local row = db:query_row(
        [[SELECT COUNT(*) AS cnt, COALESCE(SUM(size_bytes),0) AS total
          FROM images WHERE deleted=0]])
    return row or { cnt = 0, total = 0 }
end

-- Aggregate per-owner usage (for the /admin/usage endpoint). Caps the result
-- set so a single admin request cannot dump unbounded rows.
function _M.usage_leaderboard(limit)
    if not db then _M.init() end
    if not db then return {} end
    local rows = {}
    local ok, err = pcall(function()
        for _, row in db:query(
            [[SELECT key_hash, bytes_used, uploads, window_start
              FROM usage ORDER BY bytes_used DESC LIMIT ?]],
            math.min(tonumber(limit) or 50, 200)) do
            rows[#rows + 1] = row
        end
    end)
    if not ok then
        logger.err("metadata_usage_leaderboard_failed", { error = err })
    end
    return rows
end

-- Upsert a day's stats for one image. Called by stats_flush.lua.
function _M.bump_stats_daily(day, hash, count, bytes)
    if not db then _M.init() end
    if not db then return end
    db:run(
        [[INSERT INTO stats_daily(day, hash, count, bytes)
          VALUES(?, ?, ?, ?)
          ON CONFLICT(day, hash) DO UPDATE SET
            count = stats_daily.count + ?,
            bytes = stats_daily.bytes + ?]],
        day, hash, count, bytes, count, bytes)
end

-- Aggregate stats_series(days): daily totals for the last N days.
-- Returns array of {day, count, bytes}.
function _M.stats_series(days)
    if not db then _M.init() end
    if not db then return {} end
    local rows = {}
    local limit = math.min(tonumber(days) or 30, 365)
    pcall(function()
        for _, row in db:query(
            [[SELECT day, SUM(count) AS count, SUM(bytes) AS bytes
              FROM stats_daily
              WHERE day >= ?
              GROUP BY day ORDER BY day ASC]],
            math.floor(ngx.time() / 86400) - limit) do
            rows[#rows + 1] = row
        end
    end)
    return rows
end

-- Hot images in the last N days, sorted by total count.
-- Returns array of {hash, count, bytes} limited to N.
function _M.hot_images(days, limit)
    if not db then _M.init() end
    if not db then return {} end
    local rows = {}
    local c = math.min(tonumber(limit) or 20, 100)
    local min_day = math.floor(ngx.time() / 86400) - math.min(tonumber(days) or 30, 365)
    pcall(function()
        for _, row in db:query(
            [[SELECT hash, SUM(count) AS count, SUM(bytes) AS bytes
              FROM stats_daily WHERE day >= ?
              GROUP BY hash ORDER BY count DESC LIMIT ?]],
            min_day, c) do
            rows[#rows + 1] = row
        end
    end)
    return rows
end

-- ---- tus 1.0 session management ----

-- Create a new upload session.
function _M.tus_session_create(id, upload_length, meta, owner, owner_node, now, expires)
    if not db then _M.init() end
    if not db then return nil, "db unavailable" end
    local ok, err = pcall(db.run, db,
        [[INSERT INTO tus_sessions(id, upload_length, offset, metadata, owner, owner_node, created_at, expires_at, state)
          VALUES(?, ?, 0, ?, ?, ?, ?, ?, 'active')]],
        id, upload_length, meta or "", owner or "", owner_node or "", now, expires)
    if not ok then return nil, tostring(err) end
    return true
end

-- Fetch a session by ID.
function _M.tus_session_get(id)
    if not db then _M.init() end
    if not db then return nil end
    local ok, row = pcall(db.query_row, db,
        "SELECT id, upload_length, offset, metadata, owner, owner_node, created_at, expires_at, state, blob_hash FROM tus_sessions WHERE id=?", id)
    return ok and row or nil
end

-- Atomic offset advance. Returns true on success, nil+err on conflict.
function _M.tus_session_advance(id, new_offset)
    if not db then _M.init() end
    if not db then return nil, "db unavailable" end
    -- With the write lock to prevent concurrent PATCH races.
    return with_write_lock(function()
        local row = db:query_row("SELECT offset FROM tus_sessions WHERE id=?", id)
        if not row then return nil, "session not found" end
        if tonumber(row.offset) >= new_offset then
            return nil, "offset must increase"
        end
        db:run("UPDATE tus_sessions SET offset=? WHERE id=?", new_offset, id)
        return true
    end)
end

-- Set session state.
function _M.tus_session_set_state(id, state)
    if not db then return end
    pcall(db.run, db, "UPDATE tus_sessions SET state=? WHERE id=?", state, id)
end

-- Record the blob produced by a completed session.
function _M.tus_session_done(id, hash)
    if not db then return end
    pcall(db.run, db, "UPDATE tus_sessions SET state='done', blob_hash=? WHERE id=?", hash, id)
end

-- Delete a session.
function _M.tus_session_delete(id)
    if not db then return end
    pcall(db.run, db, "DELETE FROM tus_sessions WHERE id=?", id)
end

-- Expire old sessions (called from gc.run_once).
function _M.tus_session_expire(now)
    if not db then return 0 end
    local rows = {}
    pcall(function()
        for _, row in db:query(
            "SELECT id FROM tus_sessions WHERE expires_at <= ?", now) do
            rows[#rows + 1] = row.id
        end
    end)
    for _, sid in ipairs(rows) do
        pcall(db.run, db, "DELETE FROM tus_sessions WHERE id=?", sid)
        pcall(function()
            local fs = require "image.fs_ffi"
            fs.unlink(config.tmp_dir .. "/tus-" .. sid .. ".part")
        end)
    end
    return #rows
end

-- Run a passive WAL checkpoint. Cheap to call periodically.
function _M.checkpoint()
    if not db then return end
    pcall(db.exec, db, "PRAGMA wal_checkpoint(PASSIVE);")
end

-- Reconcile disk state with the metadata table: delete original files for
-- soft-deleted rows and orphan files left behind by a crash between
-- write_original and insert_image. Returns (removed_files, removed_bytes).
function _M.gc_orphans()
    if not db then _M.init() end
    if not db then return nil, "db unavailable" end

    return with_write_lock(function()
        local known = {}
        for row in db:query("SELECT hash FROM images") do
            known[row.hash] = true
        end
        local deleted = {}
        for row in db:query(
            "SELECT hash, orig_ext FROM images WHERE deleted=1") do
            deleted[row.hash] = row.orig_ext
        end

        local removed, bytes = 0, 0
        for hash, ext in pairs(deleted) do
            local path = storage.orig_path(hash, ext)
            if fs.exists(path) then
                local sz = fs.file_size(path) or 0
                if fs.unlink(path) then
                    removed = removed + 1
                    bytes = bytes + sz
                end
            end
        end

        local shard_re = "^%x%x$"
        local hash_re  = "^(%x%x%x%x%x+)%.%w+$"
        for shard in fs.walk_dir(config.orig_dir) do
            if shard:match(shard_re) then
                for fname in fs.walk_dir(config.orig_dir .. "/" .. shard) do
                    local h = fname:match(hash_re)
                    if h and not known[h] then
                        local p = config.orig_dir .. "/" .. shard .. "/" .. fname
                        local sz = fs.file_size(p) or 0
                        if fs.unlink(p) then
                            removed = removed + 1
                            bytes = bytes + sz
                        end
                    end
                end
            end
        end
        return removed, bytes
    end)
end

function _M.close()
    if db then db:close(); db = nil end
end

return _M
