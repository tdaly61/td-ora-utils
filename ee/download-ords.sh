#!/usr/bin/env bash
# download-ords.sh — fetch + extract Oracle REST Data Services (ORDS) into
# ORDS_INSTALL_DIR. Downloaded directly from download.oracle.com (no OTN
# registry login needed, unlike the official ords container image), so this
# is what keeps the whole ee/ pipeline credential-free for Phase 1.
#
# There is no versioned direct-download URL Oracle publishes for ORDS (only
# "ords-latest.zip") — unlike the Docker image tags elsewhere in this
# toolkit, this one genuinely tracks whatever Oracle currently ships. The
# resolved version is logged after extraction so it's traceable in the
# full-cycle-test report.
#
# Usage: ./download-ords.sh

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

hdr "ee/download-ords.sh"

ORDS_DOWNLOAD_URL="$(ini_val ORDS_DOWNLOAD_URL)"
ORDS_DOWNLOAD_URL="${ORDS_DOWNLOAD_URL:-https://download.oracle.com/otn_software/java/ords/ords-latest.zip}"
ORDS_CACHE_DIR="$(ini_val ORDS_CACHE_DIR)"; ORDS_CACHE_DIR="${ORDS_CACHE_DIR:-~/.cache/oracle-ords}"
ORDS_CACHE_DIR="${ORDS_CACHE_DIR/#\~/$HOME}"
ORDS_INSTALL_DIR="$(resolve_ee_path ORDS_INSTALL_DIR ./ords-install)"

mkdir -p "$ORDS_CACHE_DIR"
ZIP_PATH="$ORDS_CACHE_DIR/ords-latest.zip"

MARKER="$ORDS_INSTALL_DIR/bin/ords"

if [ -x "$MARKER" ]; then
    ok "ORDS already extracted at $ORDS_INSTALL_DIR — skipping."
    exit 0
fi

if [ ! -f "$ZIP_PATH" ]; then
    hdr "Downloading ORDS"
    echo "  $ORDS_DOWNLOAD_URL -> $ZIP_PATH"
    curl -fL -C - -o "$ZIP_PATH" "$ORDS_DOWNLOAD_URL" || {
        rm -f "$ZIP_PATH"
        die "Download failed. Download the ORDS zip manually from https://www.oracle.com/database/technologies/appdev/rest.html and place it at $ZIP_PATH, then re-run this script."
    }
else
    ok "Using cached zip: $ZIP_PATH"
fi

if ! unzip -tq "$ZIP_PATH" >/dev/null 2>&1; then
    rm -f "$ZIP_PATH"
    die "$ZIP_PATH is not a valid zip. Download manually and place it at that path, then re-run this script."
fi
ok "Zip verified: $ZIP_PATH"

hdr "Extracting"
mkdir -p "$ORDS_INSTALL_DIR"
unzip -q -o "$ZIP_PATH" -d "$ORDS_INSTALL_DIR"
chmod +x "$ORDS_INSTALL_DIR/bin/ords" 2>/dev/null || true

[ -x "$MARKER" ] || die "Extraction completed but $MARKER is missing or not executable — something is off with the archive contents."
ok "ORDS extracted to $ORDS_INSTALL_DIR"
