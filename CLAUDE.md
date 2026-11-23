# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

pickup-box: a self-hosted file/photo pickup service. Senders (password) upload files and get a share link + numeric pickup code; recipients (no account) open the link or enter the code to preview/download. Shares expire, can be visit-limited, revoked, extended.

Stack: **OpenResty (Nginx + LuaJIT)**. Previews by **libvips in C** (`c/image_vips.c`) via LuaJIT FFI on the nginx thread pool; **SQLite** via FFI (`lua/image/sqlite_ffi.lua`); QR codes via **libqrencode** FFI. Production runs behind **Caddy** (automatic HTTPS) using `deploy/docker-compose.yml`.

## Commands

```bash
cp .env.example .env              # set PICKUP_PASSWORD; leave PICKUP_DOMAIN empty locally
docker compose up -d --build      # dev stack (bind-mounts lua/, static/, conf/nginx.conf)
docker compose exec pickup-box openresty -s reload   # after editing Lua/nginx.conf
python3 -I tools/e2e.py --base http://127.0.0.1 --password <pw>   # API end-to-end
python3 tools/browser_test.py --base http://127.0.0.1 --password <pw>  # Playwright UI test
resty spec/run.lua spec/unit      # unit tests (inside an OpenResty image with busted)
python3 -I tools/gen_env.py       # regenerate nginx `env` block after adding env vars
```

No docker/luajit locally by default: **GitHub Actions is the test bed** (`.github/workflows/ci.yml`: lint incl. luacheck/JS/py syntax/env-block check, unit, e2e with short-expiry + brute-force + GC, Playwright browser test, HTTPS deploy via `deploy/install.sh`, publish multi-arch image to ghcr.io, then run the published image on amd64 and arm64). Read failures with `gh run view --job <id> --log`.

## Layout

- `conf/nginx.conf` — routes. `env`/`thread_pool` in main context (env block between `#@ENV@`/`#@END_ENV@` is generated); everything else inside `http {}`. Comments outside Lua blocks use `#`.
- `lua/pickup/` — product: `config` (PICKUP_* env, size/duration parsing), `shares` (model, tokens, names), `api` (/api/*), `pages` (server-rendered HTML), `files` (file/thumb/zip/qr serving), `zip` (streaming store-only ZIP64 writer), `qr`, `sniff` (magic-byte classification), `guard` (brute-force limits), `gc`, `secret`, `init` (master/worker hooks).
- `lua/image/` — engine: `upload` (blob store()), `upload_spool` (multipart), `tus` (resumable), `storage_local` (content-addressed `orig/ab/cd/<sha256>.<ext>`), `metadata_sqlite` (schema, migrations, `tx`/`write`/`rows`), `transform`/`processing`/`vips_ffi` (previews), `apikey` (Bearer auth), `ops` (healthz/readyz/metrics).
- `lua/common/` — logger, metrics (`pickupbox_` prefix), circuit_breaker, rate_limit, crypto (HMAC), digest (CRC-32), rand (CSPRNG).
- `static/` — CSS/JS for the send page (`app.js`, own tus client) and `/me` (`me.js`); `common.js` shared.
- `deploy/` — production compose + Caddyfile + `install.sh`.

## Conventions and gotchas

- **Env vars**: read at module load. Add new ones to `.env.example`/README, then run `tools/gen_env.py` (CI fails if the nginx `env` block is stale; nginx hides undeclared vars from workers).
- **Serving files**: set headers, then `ngx.exec("/__blob/...")` (internal location, sendfile + Range). `X-Accel-Redirect` does NOT work from `content_by_lua`.
- **libvips varargs**: array options (e.g. `background`) need `VipsArrayDouble*` (`vips_array_double_newv`), never a raw C array — that segfaulted the worker. Only pass options a saver defines (`interlace` only for jpeg/png, `Q` not for gif).
- **`ngx.exit` never returns**: release locks before calling helpers that respond (see `tus.complete`).
- **DB**: `metadata.tx(fn)` re-raises fn errors unchanged (tables allowed); `db:run` raises on SQLite errors. Migrations are positional — append only.
- **Randomness**: use `common.rand` (OpenSSL), never `math.random`, for slugs/codes/ids.
- **Behind Caddy**: `TRUST_X_FORWARDED_FOR=true` makes `docker-entrypoint.sh` write `conf/realip.conf` (nginx realip from private ranges), so `limit_req`/`limit_conn` and `client_ip` see the real client. Never enable it when the app port is exposed directly.
- **Timers** run on worker 0 only. Visit counting: page open without a valid token consumes a visit and redirects to `?t=`; bots (link previews) never consume.
- Keep `PROGRESS.md` (task checklist) current; plan multi-file changes first; verify via CI.
