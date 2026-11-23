#!/usr/bin/env bash
# Backup the image hosting data: SQLite metadata (using the online .backup
# command) and the original-image directory. The result is a single
# timestamped tarball in $BACKUP_DIR.
#
# Usage:
#   BACKUP_DIR=/var/backups ./tools/backup.sh
#
# Schedule via cron or systemd timer. The backup is consistent because
# SQLite's .backup command works while the database is in use (WAL mode).
set -euo pipefail

DATA_DIR="${IMAGE_DATA_DIR:-/data/images}"
DB_PATH="${IMAGE_DB_PATH:-$DATA_DIR/image.db}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pickup-box}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"

ts=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$BACKUP_DIR"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. Consistent SQLite snapshot
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB_PATH" ]; then
    sqlite3 "$DB_PATH" ".backup '$work/image.db'"
else
    # Fallback: copy the DB files directly (safe in WAL mode if writes are
    # paused; for hot backups prefer sqlite3 .backup).
    cp -a "$DB_PATH" "$work/image.db" 2>/dev/null || true
    [ -f "$DB_PATH-wal" ] && cp -a "$DB_PATH-wal" "$work/image.db-wal"
    [ -f "$DB_PATH-shm" ] && cp -a "$DB_PATH-shm" "$work/image.db-shm"
fi

# 2. Original images (derivative cache is excluded; it is rebuildable).
if [ -d "$DATA_DIR/orig" ]; then
    cp -a "$DATA_DIR/orig" "$work/orig"
fi

# 3. Version file for provenance
{
    date -u +"backup_ts=%Y-%m-%dT%H:%M:%SZ"
    echo "hostname=$(hostname)"
} > "$work/MANIFEST"

out="$BACKUP_DIR/pickup-box-$ts.tar.zst"
if command -v zstd >/dev/null 2>&1; then
    tar -C "$work" --zstd -cf "$out" .
else
    tar -C "$work" -czf "${out%.zst}.tar.gz" .
fi

# 4. Reap old backups
find "$BACKUP_DIR" -maxdepth 1 -name 'pickup-box-*' -mtime +"$RETENTION_DAYS" -delete

echo "wrote $out"
