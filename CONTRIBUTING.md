# Contributing

Thanks for your interest! This document covers the basics of hacking on
pickup-box.

## Project Layout

```
conf/nginx.conf         — nginx config and route table
lua/common/            — logger, metrics, circuit breaker, rate limit
lua/image/             — upload, storage, metadata, transform, ops endpoints
c/image_vips.c/.h      — libvips helper compiled to image_vips.so
tools/                 — smoke tests, backup/restore scripts
spec/unit/             — busted unit tests
docs/                  — long-form documentation
```

## Local Development

```bash
cp .env.example .env
docker compose up -d --build
./tools/smoke_image.sh
```

The container bind-mounts `lua/` and `conf/nginx.conf`, so edits are picked
up with `docker compose exec pickup-box openresty -s reload`.

## Code Style

- Lua modules return a table; use `local _M = {}` / `return _M`.
- Use `ngx.log` / the structured `common.logger` for log events, not `print`.
- All environment variables follow the `IMAGE_*` prefix and are
  declared with `env ...` in `nginx.conf`.
- New C code must compile with `-Wall -Wextra -Werror` under gcc/musl and
  pass the hardened build flags in the Dockerfile.
- Add unit tests under `spec/unit/` and an entry in `tools/smoke_image.sh`
  for new endpoints or behaviors.

## Commit Messages

Use plain English in the imperative mood. Reference the task id from
PROGRESS.md if any. Example: `image: add pickup code lookup`.

## Before Opening a PR

1. All existing and new tests pass.
2. `luajit -bl` succeeds for every Lua module.
3. The Docker image builds.
4. Update `PROGRESS.md` and `docs/` for user-facing changes.
5. Do not commit `.env`, `logs/`, or build artifacts.
