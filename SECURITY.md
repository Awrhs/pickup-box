# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's
"Report a vulnerability" (private security advisory) on this repository,
with steps to reproduce and the affected version/commit.

## Threat model

pickup-box is meant to run behind the bundled Caddy reverse proxy (HTTPS).

- **Senders** authenticate with a password (`Authorization: Bearer`). Only
  `sha256(password)` is kept in memory; uploads, shares and quota usage are
  attributed to that hash. Failed logins are limited per IP (10 per 15 min).
- **Recipients** are anonymous. A share is reachable by its 10-character
  random link or its numeric pickup code. Code guesses are limited per IP
  (10 per hour) and globally (300 per hour); with 6 digits and few live shares
  guessing is impractical, but pickup codes are meant for short-lived,
  non-sensitive transfers. Use a visit limit and a short expiry for sensitive
  files.
- **Visit limits** are enforced when the pickup page is opened; opening it
  yields a signed token (HMAC-SHA256, server secret generated on first start)
  that allows reloading and downloading for a few hours. Link-preview bots do
  not consume visits. A recipient can forward the tokenised URL; the limit is a
  convenience, not DRM.
- **Uploaded content** is classified by magic bytes, never by file name. Only
  images, video and audio may be shown inline, always with `X-Content-Type-
  Options: nosniff` and a sandboxing CSP; everything else (HTML, SVG, PDF, …)
  is served as an attachment. Pages use a strict CSP without inline scripts.
- **Storage** is content-addressed by SHA-256. Expired or revoked shares stop
  working immediately; their files are deleted by the garbage collector once
  no live share references them.
- `/metrics` is never forwarded by Caddy and only answers inside the container
  unless `PICKUP_METRICS_TOKEN` is set.

## Hardening checklist

1. Use a long random `PICKUP_PASSWORD` (the installer generates one).
2. Keep the server and the image updated (`docker compose pull && docker compose up -d`).
3. Give family members their own `PICKUP_USERS` accounts with a quota instead of sharing the admin password.
4. Keep `PICKUP_MIN_FREE_PERCENT` so uploads cannot fill the disk.
