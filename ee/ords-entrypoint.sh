#!/usr/bin/env bash
# ords-entrypoint.sh — runs inside the plain-JRE "ords" container (see
# docker-compose.yml). Not part of any official Oracle image: the official
# ords container requires an OTN registry login, so Phase 1 runs ORDS
# standalone from the zip distribution instead (see download-ords.sh).
#
# First boot: installs the ORDS schema/connection pool non-interactively
# (--password-stdin). Subsequent boots: skips straight to serving, guarded
# by a marker file this script creates itself (not an ORDS-internal file,
# so it doesn't depend on guessing ORDS's config layout).
#
# Required env vars (set by docker-compose.yml):
#   SYS_PASSWORD, ORDS_PUBLIC_USER_PASSWORD, DB_HOST, DB_PORT, DB_SERVICENAME

set -euo pipefail

CONFIG_DIR="/etc/ords/config"
MARKER="$CONFIG_DIR/.installed"
LOG_DIR="$CONFIG_DIR/logs"
mkdir -p "$LOG_DIR"

if [ ! -f "$MARKER" ]; then
    echo "=== ORDS install (first boot) ==="
    printf '%s\n%s\n' "$SYS_PASSWORD" "$ORDS_PUBLIC_USER_PASSWORD" | \
        ./bin/ords --config "$CONFIG_DIR" install \
            --admin-user SYS \
            --db-hostname "$DB_HOST" \
            --db-port "$DB_PORT" \
            --db-servicename "$DB_SERVICENAME" \
            --proxy-user \
            --log-folder "$LOG_DIR" \
            --password-stdin
    touch "$MARKER"
    echo "=== ORDS install complete ==="
else
    echo "ORDS already installed (marker found at $MARKER) — skipping install."
fi

echo "=== Starting ORDS standalone ==="
# Note: unlike `install`, the `serve` command does not accept --log-folder.
exec ./bin/ords --config "$CONFIG_DIR" serve \
    --apex-images /opt/oracle/apex/images \
    --port 8080
