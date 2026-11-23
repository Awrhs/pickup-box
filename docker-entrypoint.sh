#!/bin/sh
# Make sure the data directory exists and is writable by the worker user,
# also when /data is a freshly bind-mounted host directory.
set -e
DATA_DIR="${IMAGE_DATA_DIR:-/data/images}"
mkdir -p "$DATA_DIR/orig" "$DATA_DIR/cache" "$DATA_DIR/tmp"
chown pickup:pickup "$DATA_DIR" "$DATA_DIR/orig" "$DATA_DIR/cache" "$DATA_DIR/tmp"
exec "$@"
