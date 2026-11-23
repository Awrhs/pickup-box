#!/usr/bin/env bash
# Smoke test for the image hosting subsystem.
#
# Requires: a running gateway (docker compose up -d) and curl + jq.
# Walks through:
#   1. /healthz, /readyz, /metrics
#   2. upload via /upload (multipart)
#   3. fetch original, transformed webp, thumbnail, ETag/304
#   4. /i/<hash>/info
#   5. /me/images, /admin/stats (admin key)
#   6. delete and verify 404
#
# Env:
#   BASE_URL      default http://127.0.0.1
#   API_KEY       uploader key (IMAGE_API_KEYS must include it)
#   ADMIN_KEY     admin key (name:secret:admin)
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1}"
API_KEY="${API_KEY:-test-key-upload}"
ADMIN_KEY="${ADMIN_KEY:-test-key-admin}"

pass=0; fail=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ok: $desc"; pass=$((pass+1))
    else
        echo "FAIL: $desc"; fail=$((fail+1))
    fi
}
status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Generate a valid 16x16 RGB PNG with the standard library only.
python3 - "$tmpdir/pixel.png" <<'PY'
import struct, sys, zlib
w = h = 16
raw = b"".join(b"\x00" + b"".join(bytes([x * 16, y * 16, 128]) for x in range(w)) for y in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY

echo "== health =="
check "/healthz returns 200"  test "$(status_of "$BASE_URL/healthz")" = 200
check "/readyz  returns 200"  test "$(status_of "$BASE_URL/readyz")"  = 200
check "/metrics returns 200"  test "$(status_of "$BASE_URL/metrics")"  = 200

echo "== upload =="
upload_json=$(curl -s -X POST -H "Authorization: Bearer $API_KEY" \
    -F "file=@$tmpdir/pixel.png;filename=pixel.png" "$BASE_URL/upload")
echo "$upload_json" | jq .
hash=$(echo "$upload_json" | jq -r .hash)
test -n "$hash" -a "$hash" != null

echo "== serve =="
check "original returns 200"  test "$(status_of "$BASE_URL/i/$hash.png")" = 200
check "webp  derivative 200"  test "$(status_of "$BASE_URL/i/$hash.png?w=100&fmt=webp")" = 200
check "thumb jpeg     200"    test "$(status_of "$BASE_URL/i/$hash.png?w=50")" = 200
etag=$(curl -s -D - -o /dev/null "$BASE_URL/i/$hash.png?w=100" | awk -F': *' 'tolower($1)=="etag"{gsub("\r","",$2);print $2}')
check "etag returned" test -n "$etag"
if [ -n "$etag" ]; then
    check "304 on If-None-Match" test "$(status_of -H "If-None-Match: $etag" "$BASE_URL/i/$hash.png?w=100")" = 304
fi
check "info returns 200" test "$(status_of "$BASE_URL/i/$hash/info")" = 200
check "HEAD returns 200"  test "$(curl -s -I -o /dev/null -w '%{http_code}' "$BASE_URL/i/$hash.png")" = 200

echo "== self-service =="
check "/me/images 200 with key" test "$(status_of -H "Authorization: Bearer $API_KEY" "$BASE_URL/me/images")" = 200
check "/me/images 401 no key"   test "$(status_of "$BASE_URL/me/images")" = 401
check "/sign returns 200"       test "$(status_of -H "Authorization: Bearer $API_KEY" "$BASE_URL/sign?path=/i/$hash.png&w=100")" = 200

echo "== admin =="
check "/admin       401 no key" test "$(status_of "$BASE_URL/admin")" = 401
check "/admin/stats 200 admin"  test "$(status_of -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/admin/stats")" = 200
check "/admin/usage 200 admin"  test "$(status_of -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/admin/usage")" = 200
check "/admin       200 admin"  test "$(status_of -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/admin")" = 200

echo "== delete =="
check "DELETE 204 for admin" \
    test "$(status_of -X DELETE -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/i/$hash")" = 204
check "subsequent GET returns 404" test "$(status_of "$BASE_URL/i/$hash.png")" = 404

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
