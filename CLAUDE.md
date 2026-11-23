# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

pickup-box: a self-hosted file/photo pickup service built on **OpenResty (Nginx + LuaJIT)**. Current code is an upload + storage + on-the-fly image processing baseline; share links, pickup codes and expiry are being added (see `PROGRESS.md`).

Primary language is **Lua** (OpenResty); image work is done in **C** (`c/image_vips.c`, libvips) called through LuaJIT FFI. SQLite is also accessed via FFI (`lua/image/sqlite_ffi.lua`).

## Commands

No local build step; everything runs in the container.

```bash
cp .env.example .env            # first time only; set IMAGE_API_KEYS
docker compose up -d --build
./tools/smoke_image.sh          # end-to-end smoke test (needs API_KEY/ADMIN_KEY env)
docker compose exec pickup-box openresty -s reload   # after editing lua/ or nginx.conf
busted --lpath='lua/?.lua' spec/unit                 # unit tests
```

`lua/` and `conf/nginx.conf` are bind-mounted; `lua_code_cache on` means you must reload after edits.

**CI is the primary test bed** (`.github/workflows/ci.yml`): luajit syntax + luacheck + a guard against old-name references, busted unit tests, docker build + `openresty -t`, and the compose smoke test. Use `gh run view --log-failed` to read failures.

## Layout

- `conf/nginx.conf` — route table. `env`/`thread_pool` live in main context; `limit_*_zone`, `lua_package_path`, `init_by_lua_block`, shared dicts live inside `http {}`. Comments outside Lua blocks must use `#`, not `--`.
- `lua/common/` — `logger` (JSON logs, per-request `trace_id`), `metrics` (Prometheus, prefix `pickupbox_`), `circuit_breaker`, `rate_limit` (per-key upload throttle).
- `lua/image/` — `upload`/`upload_spool`/`tus` (ingest), `storage_local` (content-addressed `ab/cd/<hash>.<ext>`), `metadata_sqlite` (schema + migrations via `PRAGMA user_version`), `transform`/`processing`/`vips_ffi` (derivatives), `download_guard`, `gc`, `cache_maintenance`, `stats_flush`, `ops` (healthz/readyz/metrics), `main` (HTTP handlers/pages).

## Conventions

- **Config is env-only**, read at module load. A new env var must be added to `conf/nginx.conf` (`env VAR;`), `docker-compose.yml`, and `.env.example`, or nginx hides it from Lua.
- **Cross-worker state** goes in a `lua_shared_dict` declared in `nginx.conf`; namespace keys.
- **Non-blocking I/O only** in request handlers. libvips calls go through `ngx.run_worker_thread` (thread pool `default`) behind a per-worker semaphore.
- **Background timers run on worker 0 only** (`ngx.worker.id() == 0`).
- Files are served via `X-Accel-Redirect` to the internal `/__image_file/` location (sendfile), not read into Lua.
- Constant-time comparisons for secrets (`apikey.lua`, `download_guard.lua`); never replace with `==`.
- Migrations in `metadata_sqlite.lua` are positional; append, never reorder or delete.

## Workflow

- Plan multi-file changes first; keep `PROGRESS.md` (the task checklist) current — check items off as phases actually complete and update when scope shifts.
- Verify via CI (push a branch / PR) since there is no local runtime by default.
