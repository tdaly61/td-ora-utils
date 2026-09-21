#!/usr/bin/env bash
# setup-for-dbfree.sh — one-time (idempotent) host prep for the dbfree/ stack:
# registry login, image pulls, host directories, APEX/ORDS download+extract.
# Does not touch adb/ or its running container.
#
# Usage: ./setup-for-dbfree.sh

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

# Fetch + extract the APEX zip into APEX_INSTALL_DIR so the ords container
# can auto-install it on first boot (bind-mounted to /opt/oracle/apex — see
# docker-compose.yml). Caches the downloaded zip under APEX_CACHE_DIR so
# repeated runs don't re-download it every time; only the extracted copy
# under APEX_INSTALL_DIR is wiped by run-dbfree.sh -c.
#
# The download URL may require an OTN login click-through in a browser
# rather than a plain curl. If curl gets back an HTML page instead of a zip,
# this fails loudly with instructions to download manually and place the
# file in the cache dir rather than silently proceeding with a broken/empty
# install.
download_apex() {
    hdr "Downloading/extracting APEX"

    local apex_version apex_download_url apex_cache_dir apex_install_dir zip_path marker staging_dir
    apex_version="$(ini_val APEX_VERSION)"; apex_version="${apex_version:-26.1}"
    apex_download_url="$(ini_val APEX_DOWNLOAD_URL)"
    apex_cache_dir="$(ini_val APEX_CACHE_DIR)"; apex_cache_dir="${apex_cache_dir:-~/.cache/oracle-apex}"
    apex_cache_dir="${apex_cache_dir/#\~/$HOME}"
    apex_install_dir="$(resolve_dbfree_path APEX_INSTALL_DIR ./apex-install)"

    [ -n "$apex_download_url" ] || die "APEX_DOWNLOAD_URL not set in dbfree/.env"

    mkdir -p "$apex_cache_dir"
    zip_path="$apex_cache_dir/apex_${apex_version}_en.zip"

    # Marker: a file that only exists once the real APEX distribution is extracted.
    marker="$apex_install_dir/apexins.sql"

    if [ -f "$marker" ]; then
        ok "APEX already extracted at $apex_install_dir — skipping."
        return 0
    fi

    if [ ! -f "$zip_path" ]; then
        echo "  Downloading APEX $apex_version"
        echo "  $apex_download_url -> $zip_path"
        curl -fL -C - -o "$zip_path" "$apex_download_url" || {
            rm -f "$zip_path"
            die "Download failed. If this URL now requires an OTN login click-through, download apex_${apex_version}_en.zip manually from https://www.oracle.com/tools/downloads/apex-downloads/ and place it at $zip_path, then re-run."
        }
    else
        ok "Using cached zip: $zip_path"
    fi

    # Verify it's actually a zip, not an HTML login/error page saved with a .zip name.
    if ! unzip -tq "$zip_path" >/dev/null 2>&1; then
        rm -f "$zip_path"
        die "$zip_path is not a valid zip (likely an HTML login page was downloaded instead). Download apex_${apex_version}_en.zip manually and place it at that path, then re-run."
    fi
    ok "Zip verified: $zip_path"

    staging_dir="$(mktemp -d)"
    trap 'rm -rf "$staging_dir"' RETURN
    unzip -q "$zip_path" -d "$staging_dir"

    [ -d "$staging_dir/apex" ] || die "Expected an 'apex/' directory inside the zip but didn't find one — Oracle may have changed the archive layout for $apex_version."

    mkdir -p "$apex_install_dir"
    # Copy (not move) the inner apex/ folder's *contents* directly into
    # APEX_INSTALL_DIR, since that's what gets bind-mounted to /opt/oracle/apex.
    cp -a "$staging_dir/apex/." "$apex_install_dir/"

    [ -f "$marker" ] || die "Extraction completed but $marker is still missing — something is off with the archive contents."
    ok "APEX $apex_version extracted to $apex_install_dir"
}

# Fetch + extract Oracle REST Data Services (ORDS) into ORDS_INSTALL_DIR.
# Downloaded directly from download.oracle.com — no OTN registry login
# needed here, unlike the official ords container image (or the DB image
# itself, which does need one — see .env.sample).
#
# There is no versioned direct-download URL Oracle publishes for ORDS (only
# "ords-latest.zip") — unlike the Docker image tags elsewhere in this
# toolkit, this one genuinely tracks whatever Oracle currently ships.
download_ords() {
    hdr "Downloading/extracting ORDS"

    local ords_download_url ords_cache_dir ords_install_dir zip_path marker
    ords_download_url="$(ini_val ORDS_DOWNLOAD_URL)"
    ords_download_url="${ords_download_url:-https://download.oracle.com/otn_software/java/ords/ords-latest.zip}"
    ords_cache_dir="$(ini_val ORDS_CACHE_DIR)"; ords_cache_dir="${ords_cache_dir:-~/.cache/oracle-ords}"
    ords_cache_dir="${ords_cache_dir/#\~/$HOME}"
    ords_install_dir="$(resolve_dbfree_path ORDS_INSTALL_DIR ./ords-install)"

    mkdir -p "$ords_cache_dir"
    zip_path="$ords_cache_dir/ords-latest.zip"

    marker="$ords_install_dir/bin/ords"

    if [ -x "$marker" ]; then
        ok "ORDS already extracted at $ords_install_dir — skipping."
        return 0
    fi

    if [ ! -f "$zip_path" ]; then
        echo "  Downloading ORDS"
        echo "  $ords_download_url -> $zip_path"
        curl -fL -C - -o "$zip_path" "$ords_download_url" || {
            rm -f "$zip_path"
            die "Download failed. Download the ORDS zip manually from https://www.oracle.com/database/technologies/appdev/rest.html and place it at $zip_path, then re-run."
        }
    else
        ok "Using cached zip: $zip_path"
    fi

    if ! unzip -tq "$zip_path" >/dev/null 2>&1; then
        rm -f "$zip_path"
        die "$zip_path is not a valid zip. Download manually and place it at that path, then re-run."
    fi
    ok "Zip verified: $zip_path"

    mkdir -p "$ords_install_dir"
    unzip -q -o "$zip_path" -d "$ords_install_dir"
    chmod +x "$ords_install_dir/bin/ords" 2>/dev/null || true

    [ -x "$marker" ] || die "Extraction completed but $marker is missing or not executable — something is off with the archive contents."
    ok "ORDS extracted to $ords_install_dir"
}

hdr "dbfree/setup-for-dbfree.sh"

REGISTRY_USER="$(ini_val ORACLE_REGISTRY_USER)"
REGISTRY_PASSWORD="$(ini_val ORACLE_REGISTRY_PASSWORD)"
# Arch-aware — DOCKER_IMAGE_ARM on arm64/aarch64, DOCKER_IMAGE_AMD on
# x86_64, same select_docker_image() helper ../adb/ itself uses (falls back
# to plain DOCKER_IMAGE if neither arch key is set).
DOCKER_IMAGE="$(select_docker_image)"
ORDS_JAVA_IMAGE="$(ini_val ORDS_JAVA_IMAGE)"; ORDS_JAVA_IMAGE="${ORDS_JAVA_IMAGE:-eclipse-temurin:21-jre-jammy}"

[ -n "$DOCKER_IMAGE" ] || die "DOCKER_IMAGE_ARM/DOCKER_IMAGE_AMD (or DOCKER_IMAGE) not set in dbfree/.env"

if [[ "$DOCKER_IMAGE" == *:latest ]]; then
    die "Refusing to use :latest — pin an explicit tag for DOCKER_IMAGE (see .env.sample)."
fi

REGISTRY_HOST="container-registry.oracle.com"
if [[ "$DOCKER_IMAGE" == "$REGISTRY_HOST"* ]]; then
    if [ -n "$REGISTRY_USER" ] && [ "$REGISTRY_USER" != "your-oracle-sso-email@example.com" ]; then
        hdr "Docker login to $REGISTRY_HOST"
        echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin
        ok "Logged in to $REGISTRY_HOST"
    else
        warn "ORACLE_REGISTRY_USER not set — attempting unauthenticated pull (will fail if the licence hasn't been accepted for this image)."
    fi
fi

hdr "Pulling images"
echo "  DB image        : $DOCKER_IMAGE"
docker pull "$DOCKER_IMAGE" || die "Failed to pull $DOCKER_IMAGE — verify the tag exists on the registry and the licence has been accepted."
ok "Pulled $DOCKER_IMAGE"

echo "  ORDS base image : $ORDS_JAVA_IMAGE"
docker pull "$ORDS_JAVA_IMAGE" || die "Failed to pull $ORDS_JAVA_IMAGE"
ok "Pulled $ORDS_JAVA_IMAGE"

# Used by run-dbfree.sh -c to reliably wipe DB-owned files/dirs regardless of
# host-vs-container uid mismatches (see run-dbfree.sh for why).
docker pull alpine || die "Failed to pull alpine"
ok "Pulled alpine (used by run-dbfree.sh -c for cleanup)"

hdr "Host directories"
DB_DATA_DIR="$(resolve_dbfree_path DB_DATA_DIR ./oradata)"
ORDS_CONFIG_DIR="$(resolve_dbfree_path ORDS_CONFIG_DIR ./ords_config)"
APEX_INSTALL_DIR="$(resolve_dbfree_path APEX_INSTALL_DIR ./apex-install)"
ORDS_INSTALL_DIR="$(resolve_dbfree_path ORDS_INSTALL_DIR ./ords-install)"

for d in "$DB_DATA_DIR" "$ORDS_CONFIG_DIR" "$APEX_INSTALL_DIR" "$ORDS_INSTALL_DIR"; do
    mkdir -p "$d"
    # Oracle's container images run as a fixed internal UID (commonly 54321)
    # and need to write to these bind mounts — chmod wide open here is a
    # deliberate POC-only shortcut (this repo is explicitly demo/POC scope,
    # see td-ora-utils/CLAUDE.md), not a production pattern.
    chmod 777 "$d"
    ok "Ready: $d"
done

download_apex
download_ords

echo ""
ok "Setup complete. Next: ./run-dbfree.sh"
