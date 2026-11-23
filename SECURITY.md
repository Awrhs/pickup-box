# Security Policy

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email the maintainer(s) with a description of the issue, reproduction steps,
and the commit/version affected. Expect an acknowledgement within 72 hours.

Please do not disclose the issue publicly until a fix has been released and
end users have had time to upgrade.

## Threat Model

pickup-box is intended to be deployed behind a TLS-terminating reverse
proxy (Caddy, nginx, Cloudflare, ...). It is not hardened to be exposed
directly on the public internet.

The service treats API keys as bearer tokens:
- Secrets are stored only as `sha256(secret)` in memory and in the database.
- API keys may be provided via `Authorization: Bearer ...` (recommended) or
  `?api_key=...` (legacy; can be disabled with `IMAGE_ALLOW_QUERY_KEY=false`).
- Plain-text secrets are never written to logs (the access log format for
  image endpoints omits the query string).
- Downloads may be HMAC-signed (`IMAGE_DOWNLOAD_SIGNED_URLS=true`); signatures
  cover the path, expiry, and all transform parameters.

## Hardening Checklist for Production

1. Set a strong `IMAGE_DOWNLOAD_SECRET` (≥32 chars,
   unique, random).
2. Set `IMAGE_ALLOW_QUERY_KEY=false`.
3. Set `IMAGE_REQUIRE_STRONG_SECRET=true`.
4. Run behind HTTPS; the gateway itself does not terminate TLS.
5. Set `TRUST_X_FORWARDED_FOR=true` and `IMAGE_TRUSTED_PROXY_HOPS=<n>` if
   deployed behind a reverse proxy. Without this, all requests appear to
   come from the proxy IP and per-IP limits are ineffective.
6. Use `IMAGE_DEFAULT_QUOTA_BYTES` and per-key quotas.
7. Enable `IMAGE_DOWNLOAD_REFERER_MODE=allow` with a host allow list, or
   require signed URLs (`IMAGE_DOWNLOAD_SIGNED_URLS=true`).
8. Mount `/data` on a persistent, encrypted volume and set up backups.
9. Restart on a schedule (or enable live reload for the API key file) when
   using `IMAGE_API_KEY_FILE` for key rotation.

## Known Limitations

- There is no built-in virus scanning; uploads are validated by magic
  bytes and pixel dimensions only.
- Original images are stored verbatim. If you serve the public internet,
  set `IMAGE_ORIGINAL_DISPOSITION=attachment` or front the gateway with a
  CDN that re-encodes images, to defeat polyglot files.
- Multi-node deployments share no state (SQLite is local, rate-limits are
  per-node). Use a sticky-session load balancer or externalize state.
