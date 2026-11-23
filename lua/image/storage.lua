-- Storage backend factory. `require "image.storage"` returns a backend
-- implementation chosen by IMAGE_STORAGE_BACKEND at module load time:
--
--   "local"  (default, only option) — content-addressed filesystem,
--                        served via X-Accel-Redirect
--
-- Backends must implement (path semantics):
--   orig_path(hash, ext)
--   ensure_local_orig(hash, ext)  -> path | nil, err
--   place_orig(tmp, hash, ext)    -> path, existed | nil, err
--   cache_path(hash, cache_key, ext)
--   write_original(hash, ext, data)   -> path, existed
--   write_cache(path, data)           -> ok, err
--   read(path) / exists(path) / size(path)
--   delete_orig(hash, ext)
--   purge_cache(hash)
--   to_internal_uri(abs_path)         -> uri or nil (stream locally)
local config = require "image.config"

local backend = config.storage_backend or "local"
if backend == "local" then
    return require "image.storage_local"
else
    error("unknown IMAGE_STORAGE_BACKEND: " .. tostring(backend))
end
