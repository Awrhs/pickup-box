#!/usr/bin/env bash
# Restore from a backup produced by tools/backup.sh.
#
# Usage:
#   ./tools/restore.sh /var/backups/pickup-box/pickup-box-20260101T000000Z.tar.zst
#
# The restore stops the gateway, overwrites the data directory, and starts
# it again. Re-run at your own risk — take a fresh backup first if the
# current data is valuable.
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <backup.tar.zst|backup.tar.gz>" >&2
    exit 2
fi
archive="$1"
if [ ! -f "$archive" ]; then
    echo "archive not found: $archive" >&2
    exit 1
fi

DATA_DIR="${IMAGE_DATA_DIR:-/data/images}"
DB_PATH="${IMAGE_DB_PATH:-$DATA_DIR/image.db}"

echo "About to replace $DATA_DIR with $archive."
read -r -p "Type 'yes' to continue: " confirm
[ "$confirm" = "yes" ] || { echo "aborted"; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$archive" in
    *.zst) tar --zstd -xf "$archive" -C "$work" ;;
    *.gz)  tar -xzf "$archive" -C "$work" ;;
    *)     echo "unknown archive format"; exit 1 ;;
esac

if command -v docker >/dev/null 2>&1; then
    docker compose stop pickup-box 2>/dev/null || true
fi

rm -rf "${DATA_DIR:?}/orig" "${DATA_DIR:?}/cache"
mkdir -p "$DATA_DIR"
[ -d "$work/orig" ] && cp -a "$work/orig" "$DATA_DIR/orig"
[ -f "$work/image.db" ] && cp -a "$work/image.db" "$DB_PATH"
[ -f "$work/image.db-wal" ] && cp -a "$work/image.db-wal" "$DB_PATH-wal"
[ -f "$work/image.db-shm" ] && cp -a "$work/image.db-shm" "$DB_PATH-shm"

if command -v docker >/dev/null 2>&1; then
    docker compose start pickup-box
fi

echo "restored from $archive"
