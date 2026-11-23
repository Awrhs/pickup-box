# Changelog

All notable changes to this project are documented here. The format is
loosely based on Keep a Changelog.

## Unreleased

- Initial public baseline: self-hosted upload service on OpenResty +
  LuaJIT FFI + libvips (resumable tus uploads, content-addressed storage,
  SQLite metadata, on-the-fly thumbnails, per-key quotas, download rate
  limiting, Prometheus metrics).
- Next: turn it into a file/photo pickup service (share links, pickup
  codes, expiry). See `PROGRESS.md`.
