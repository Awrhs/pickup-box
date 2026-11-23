# Changelog

## Unreleased

### Added
- File and photo pickup service: shares with a link, a 6-digit pickup code,
  QR code, expiry, optional visit limit, revoke and extend.
- Send page with resumable uploads (tus) and a "my shares" page; pickup
  page that works without JavaScript; streamed zip download (ZIP64).
- Any file type, classified by content; previews for images (incl. HEIC),
  inline playback for video and audio with Range support.
- Brute-force limits for pickup codes and passwords; link-preview bots do
  not consume visits.
- `deploy/` with Caddy (automatic HTTPS) and a one-step `install.sh`;
  multi-arch images on ghcr.io.

### Fixed
- Files were never actually served (X-Accel-Redirect from content_by_lua).
- tus PATCH bodies buffered by nginx were silently dropped.
- Worker segfault when rendering JPEG (raw array passed to vips_flatten).
- nginx configuration that could not start; C helper that did not compile;
  API keys in the documented `name:secret:role` form were rejected.
