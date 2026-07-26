#!/usr/bin/env bash
# download-apex.sh — fetch + extract the APEX zip into APEX_INSTALL_DIR so the
# ords container can auto-install it on first boot (bind-mounted to
# /opt/oracle/apex — see docker-compose.yml).
#
# Caches the downloaded zip under APEX_CACHE_DIR so repeated full-cycle test
# runs don't re-download it every time; only the extracted copy under
# APEX_INSTALL_DIR is wiped by run-ee.sh -c.
#
# Known open risk (documented in the ee POC plan): the download URL may
# require an OTN login click-through in a browser rather than a plain curl.
# If curl gets back an HTML page instead of a zip, this script fails loudly
# with instructions to download manually and place the file in the cache dir
# rather than silently proceeding with a broken/empty install.
#
# Usage: ./download-apex.sh

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

hdr "ee/download-apex.sh"

APEX_VERSION="$(ini_val APEX_VERSION)"; APEX_VERSION="${APEX_VERSION:-26.1}"
APEX_DOWNLOAD_URL="$(ini_val APEX_DOWNLOAD_URL)"
APEX_CACHE_DIR="$(ini_val APEX_CACHE_DIR)"; APEX_CACHE_DIR="${APEX_CACHE_DIR:-~/.cache/oracle-apex}"
APEX_CACHE_DIR="${APEX_CACHE_DIR/#\~/$HOME}"
APEX_INSTALL_DIR="$(resolve_ee_path APEX_INSTALL_DIR ./apex-install)"

[ -n "$APEX_DOWNLOAD_URL" ] || die "APEX_DOWNLOAD_URL not set in ee/.env"

mkdir -p "$APEX_CACHE_DIR"
ZIP_PATH="$APEX_CACHE_DIR/apex_${APEX_VERSION}_en.zip"

# Marker: a file that only exists once the real APEX distribution is extracted.
MARKER="$APEX_INSTALL_DIR/apexins.sql"

if [ -f "$MARKER" ]; then
    ok "APEX already extracted at $APEX_INSTALL_DIR — skipping."
    exit 0
fi

if [ ! -f "$ZIP_PATH" ]; then
    hdr "Downloading APEX $APEX_VERSION"
    echo "  $APEX_DOWNLOAD_URL -> $ZIP_PATH"
    curl -fL -C - -o "$ZIP_PATH" "$APEX_DOWNLOAD_URL" || {
        rm -f "$ZIP_PATH"
        die "Download failed. If this URL now requires an OTN login click-through, download apex_${APEX_VERSION}_en.zip manually from https://www.oracle.com/tools/downloads/apex-downloads/ and place it at $ZIP_PATH, then re-run this script."
    }
else
    ok "Using cached zip: $ZIP_PATH"
fi

# Verify it's actually a zip, not an HTML login/error page saved with a .zip name.
if ! unzip -tq "$ZIP_PATH" >/dev/null 2>&1; then
    rm -f "$ZIP_PATH"
    die "$ZIP_PATH is not a valid zip (likely an HTML login page was downloaded instead). Download apex_${APEX_VERSION}_en.zip manually and place it at that path, then re-run this script."
fi
ok "Zip verified: $ZIP_PATH"

hdr "Extracting"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
unzip -q "$ZIP_PATH" -d "$STAGING_DIR"

[ -d "$STAGING_DIR/apex" ] || die "Expected an 'apex/' directory inside the zip but didn't find one — Oracle may have changed the archive layout for $APEX_VERSION."

mkdir -p "$APEX_INSTALL_DIR"
# Copy (not move) the inner apex/ folder's *contents* directly into
# APEX_INSTALL_DIR, since that's what gets bind-mounted to /opt/oracle/apex.
cp -a "$STAGING_DIR/apex/." "$APEX_INSTALL_DIR/"

[ -f "$MARKER" ] || die "Extraction completed but $MARKER is still missing — something is off with the archive contents."
ok "APEX $APEX_VERSION extracted to $APEX_INSTALL_DIR"
