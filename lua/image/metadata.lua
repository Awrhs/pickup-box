-- Metadata backend dispatch.
--
-- `require "image.metadata"` returns exactly one backend module table; every
-- caller (upload, transform, admin, gc, ...) is agnostic of the engine.
--
-- Backends:
--   * image.metadata_sqlite — zero-dependency, single-node default. SQLite
--     over FFI with WAL + a per-worker write semaphore.
--
-- A backend MUST provide the function set:
--   init, apply_migrations, ready, usage_for, insert_with_quota,
--   insert_image, get_image, soft_delete, list_by_owner, recent, count,
--   get_slug, ensure_slug, soft_delete_many, stats, usage_leaderboard,
--   checkpoint, gc_orphans, close
-- (plus the per-feature additions: phash, stats_daily, tus_sessions —
-- see the implementation for the full list).
--
-- Env wiring: IMAGE_METADATA_BACKEND must be declared with an `env` directive
-- in nginx.conf or Nginx hides it from the Lua VM.
local backend = (os.getenv("IMAGE_METADATA_BACKEND") or "sqlite"):lower()

if backend == "sqlite" then
    return require "image.metadata_sqlite"
end

error("unknown IMAGE_METADATA_BACKEND: " .. tostring(backend)
    .. " (expected sqlite)")
