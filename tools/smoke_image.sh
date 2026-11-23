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

# Canonical 1x1 white JPEG (widely-used fixture; vips can decode it).
base64 -d > "$tmpdir/pixel.jpg" <<'EOF'
/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a
HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy
MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIA
AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAA
AAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AL+AB//Z
EOF

echo "== health =="
check "/healthz returns 200"  test "$(status_of "$BASE_URL/healthz")" = 200
check "/readyz  returns 200"  test "$(status_of "$BASE_URL/readyz")"  = 200
check "/metrics returns 200"  test "$(status_of "$BASE_URL/metrics")"  = 200

echo "== upload =="
upload_json=$(curl -s -X POST -H "Authorization: Bearer $API_KEY" \
    -F "file=@$tmpdir/pixel.jpg;filename=pixel.jpg" "$BASE_URL/upload")
echo "$upload_json" | jq .
hash=$(echo "$upload_json" | jq -r .hash)
test -n "$hash" -a "$hash" != null

echo "== serve =="
check "original returns 200"  test "$(status_of "$BASE_URL/i/$hash.jpg")" = 200
check "webp  derivative 200"  test "$(status_of "$BASE_URL/i/$hash.jpg?w=100&fmt=webp")" = 200
check "thumb jpeg     200"    test "$(status_of "$BASE_URL/i/$hash.jpg?w=50")" = 200
etag=$(curl -s -D - -o /dev/null "$BASE_URL/i/$hash.jpg?w=100" | awk -F': *' 'tolower($1)=="etag"{gsub("\r","",$2);print $2}')
check "etag returned" test -n "$etag"
if [ -n "$etag" ]; then
    check "304 on If-None-Match" test "$(status_of -H "If-None-Match: $etag" "$BASE_URL/i/$hash.jpg?w=100")" = 304
fi
check "info returns 200" test "$(status_of "$BASE_URL/i/$hash/info")" = 200
check "HEAD returns 200"  test "$(curl -s -I -o /dev/null -w '%{http_code}' "$BASE_URL/i/$hash.jpg")" = 200

echo "== self-service =="
check "/me/images 200 with key" test "$(status_of -H "Authorization: Bearer $API_KEY" "$BASE_URL/me/images")" = 200
check "/me/images 401 no key"   test "$(status_of "$BASE_URL/me/images")" = 401
check "/sign returns 200"       test "$(status_of -H "Authorization: Bearer $API_KEY" "$BASE_URL/sign?path=/i/$hash.jpg&w=100")" = 200

echo "== admin =="
check "/admin       401 no key" test "$(status_of "$BASE_URL/admin")" = 401
check "/admin/stats 200 admin"  test "$(status_of -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/admin/stats")" = 200
check "/admin/usage 200 admin"  test "$(status_of -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/admin/usage")" = 200
check "/admin       200 admin"  test "$(status_of -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/admin")" = 200

echo "== delete =="
check "DELETE 204 for admin" \
    test "$(status_of -X DELETE -H "Authorization: Bearer $ADMIN_KEY" "$BASE_URL/i/$hash")" = 204
check "subsequent GET returns 404" test "$(status_of "$BASE_URL/i/$hash.jpg")" = 404

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
