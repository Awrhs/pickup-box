# HTTP API

All API requests authenticate with the upload password:
`Authorization: Bearer <password>`. Responses are JSON; errors look like
`{"error": "quota_exceeded", "message": "上传额度已用完"}`.

## Quick start with curl

Upload files and share them in one request:

```bash
curl -H "Authorization: Bearer $PW" \
     -F file=@photo.jpg -F file=@video.mp4 \
     "https://files.example.com/api/upload?share=1&expires_in=3d&max_visits=0&title=Trip"
```

The response contains `code` (pickup code), `url` (share link), `qr_url`,
`expires_at` and the file list.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/config` | Public limits (max file size, expiry choices, code length). No auth. |
| GET | `/api/me` | `{name, role, quota_bytes, used_bytes, left_bytes}` |
| POST | `/api/upload` | multipart/form-data, one or more `file` parts. Returns `{files: [{hash, name, size, kind}]}`. With `?share=1` (plus optional `expires_in`, `max_visits`, `title`) also creates a share and returns it. |
| POST | `/api/shares` | Body `{"files": [{"hash": "...", "name": "a.jpg"}], "expires_in": 604800, "max_visits": 0, "title": ""}` |
| GET | `/api/shares` | Your shares (admins: `?all=1` for everyone's). `limit`, `offset` supported. |
| GET | `/api/shares/<id>` | One share including its files |
| POST | `/api/shares/<id>/extend` | `{"expires_in": 604800}`: new lifetime counted from now |
| POST | `/api/shares/<id>/revoke` | Stop sharing immediately (also `DELETE /api/shares/<id>`) |
| POST | `/api/shares/<id>/preview` | Owner link that does not consume a visit |
| GET | `/api/blobs/<sha256>` | (admin) Is this content stored? |

`expires_in` accepts seconds or a duration such as `90m`, `24h`, `7d`.
`max_visits = 0` means unlimited.

## Resumable uploads (tus 1.0)

Large files are uploaded with the [tus protocol](https://tus.io/protocols/resumable-upload)
at `/files/` (extensions: creation, expiration, termination, checksum).
The final `PATCH` (and `HEAD` on a finished upload) returns `X-Blob-Hash`,
`X-Blob-Kind` and `X-Blob-Size`; pass the hash to `POST /api/shares`.

```bash
# create
curl -i -X POST -H "Authorization: Bearer $PW" -H "Tus-Resumable: 1.0.0" \
     -H "Upload-Length: $(stat -c%s big.mov)" https://files.example.com/files/
# upload (repeat with the returned Upload-Offset after an interruption)
curl -i -X PATCH -H "Authorization: Bearer $PW" -H "Tus-Resumable: 1.0.0" \
     -H "Upload-Offset: 0" -H "Content-Type: application/offset+octet-stream" \
     --data-binary @big.mov https://files.example.com/files/<id>
```

A single `PATCH` may carry at most 64 MiB; split bigger files into chunks.

## Public pages (no auth)

| Path | Description |
| --- | --- |
| `/` | Home: enter a pickup code, or send files |
| `/c/<code>`, `/c?code=` | Redirect to the share for a pickup code |
| `/p/<slug>` | Pickup page (counts one visit, then redirects to `?t=<token>`) |
| `/p/<slug>/f/<n>` | File `n` (`?dl=1` forces download; supports Range) |
| `/p/<slug>/f/<n>/thumb?s=s\|l` | Image preview, 320 or 1280 px wide |
| `/p/<slug>/zip` | All files as a zip |
| `/p/<slug>/qr.svg` | QR code of the share link |

For shares with a visit limit, file URLs need the `t` token from the pickup
page; unlimited shares can be linked directly.
