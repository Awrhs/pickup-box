# Contributing

## Layout

```
conf/nginx.conf      routes and nginx settings
lua/pickup/          product logic: shares, pages, API, zip, QR, GC
lua/image/           engine: uploads (multipart + tus), storage, SQLite, previews
lua/common/          logger, metrics, crypto, digest, rand, rate limit
c/image_vips.c       libvips helper compiled to image_vips.so (previews, digests)
static/              CSS and JavaScript for the send page and /me
deploy/              production compose, Caddyfile, install.sh
tools/               e2e.py (API), browser_test.py (Playwright), gen_env.py
spec/unit/           busted unit tests (run under the resty CLI)
```

## Local development

```bash
cp .env.example .env            # set PICKUP_PASSWORD, leave PICKUP_DOMAIN empty
docker compose up -d --build
python3 -I tools/e2e.py --base http://127.0.0.1 --password "$PICKUP_PASSWORD"
```

`lua/`, `static/` and `conf/nginx.conf` are bind-mounted; apply changes with
`docker compose exec pickup-box openresty -s reload`.

## Rules

- Configuration is environment variables only. After adding one, document it
  in `.env.example`/README and run `python3 -I tools/gen_env.py`.
- Use `common.rand` for anything that must be unguessable.
- Serve stored files through `ngx.exec` to the internal `/__blob/` location.
- New endpoints need coverage in `tools/e2e.py`; UI changes in
  `tools/browser_test.py`.
- C code must build warning-free with the hardened flags in the Dockerfile.

## Testing a real public deployment

`Actions → Public demo → Run workflow` deploys the published image with
`deploy/install.sh` on a runner, exposes it through a Cloudflare quick tunnel,
runs `tools/e2e.py` and the browser test against the public HTTPS hostname,
obtains a Let's Encrypt certificate with the unmodified `deploy/Caddyfile`,
and stays online for the requested minutes (needs the `DEMO_PASSWORD`
repository secret). It is a test deployment, not hosting.

## Before opening a PR

CI must be green: lint, unit, e2e, browser and deploy jobs.
