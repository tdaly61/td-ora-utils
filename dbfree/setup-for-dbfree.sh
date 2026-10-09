#!/usr/bin/env bash
# setup-for-dbfree.sh — one-time (idempotent) host prep for the dbfree/ stack:
# registry login, image pulls, host directories, APEX/ORDS download+extract.
#
# Usage: ./setup-for-dbfree.sh

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

REGISTRY_HOST="container-registry.oracle.com"
REGISTRY_PLACEHOLDER_USER="your-oracle-sso-email@example.com"
REGISTRY_PLACEHOLDER_PASSWORD="CHANGE_ME_oracle_registry_token"

# ══════════════════════════════════════════════════════════════════════════
# Shared helpers
# ══════════════════════════════════════════════════════════════════════════

# Expand a leading ~ in a path (ini values are read literally from .env).
expand_tilde() { echo "${1/#\~/$HOME}"; }

# Make sure $zip_path holds a valid zip, downloading it from $url if absent.
# Reuses a cached copy when present; removes anything that isn't a real zip
# (e.g. an HTML login page saved under a .zip name) and dies with $manual_hint.
#   fetch_zip <label> <url> <zip_path> <manual_hint>
fetch_zip() {
    local label="$1" url="$2" zip_path="$3" manual_hint="$4"

    if [ ! -f "$zip_path" ]; then
        echo "  Downloading $label"
        echo "  $url -> $zip_path"
        curl -fL -C - -o "$zip_path" "$url" || {
            rm -f "$zip_path"
            die "Download failed. $manual_hint"
        }
    else
        ok "Using cached zip: $zip_path"
    fi

    if ! unzip -tq "$zip_path" >/dev/null 2>&1; then
        rm -f "$zip_path"
        die "$zip_path is not a valid zip (likely an HTML login page was downloaded instead). $manual_hint"
    fi
    ok "Zip verified: $zip_path"
}

# ══════════════════════════════════════════════════════════════════════════
# Preflight: catch every fixable problem up front, before any registry
# login, pull, or download. Failures accumulate in PREFLIGHT_FAILURES and
# print together (not fail-fast) so one run tells you everything wrong, not
# just the first thing. Modeled on caseweave's utils/jobs.sh `preflight`.
# ══════════════════════════════════════════════════════════════════════════
PREFLIGHT_FAILURES=0
preflight_fail() { fail "$1"; PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1)); }

check_docker_daemon() {
    if docker info &>/dev/null; then
        ok "Docker daemon is reachable"
    else
        preflight_fail "Docker daemon is not reachable — start Colima (\`colima start\`) or Docker Desktop, then re-run."
    fi
}

check_docker_compose() {
    if docker compose version &>/dev/null; then
        ok "docker compose plugin is wired up"
    elif command -v docker-compose &>/dev/null; then
        warn "docker compose (the CLI plugin) isn't wired up, but a standalone docker-compose binary exists — fixing automatically."
        mkdir -p "$HOME/.docker/cli-plugins"
        ln -sf "$(command -v docker-compose)" "$HOME/.docker/cli-plugins/docker-compose"
        if docker compose version &>/dev/null; then
            ok "docker compose now works (symlinked into ~/.docker/cli-plugins/)"
        else
            preflight_fail "Symlinking docker-compose into ~/.docker/cli-plugins/ didn't fix it — check docker compose version manually."
        fi
    else
        preflight_fail "docker compose is not available at all — install Docker Compose v2 (e.g. \`brew install docker-compose\` on macOS) and re-run."
    fi
}

check_grealpath() {
    [ "$PLATFORM" = "darwin" ] || return 0
    if command -v grealpath &>/dev/null; then
        ok "grealpath is available"
    else
        preflight_fail "grealpath not found — run: brew install coreutils"
    fi
}

check_disk_space() {
    local avail_kb min_kb=$((20 * 1024 * 1024))
    avail_kb="$(avail_kb_for_dir "$DBFREE_DIR")"
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$min_kb" ] 2>/dev/null; then
        warn "Only $((avail_kb / 1024 / 1024))GB free near $DBFREE_DIR — the DB image, APEX/ORDS zips, and oradata growth want ~20GB+. Not blocking, but watch for disk-full errors mid-run."
    else
        ok "Disk space looks sufficient ($((avail_kb / 1024 / 1024))GB free)"
    fi
}

check_registry_credentials() {
    local reg_user reg_pass
    reg_user="$(ini_val ORACLE_REGISTRY_USER)"
    reg_pass="$(ini_val ORACLE_REGISTRY_PASSWORD)"
    if [ "$reg_user" = "$REGISTRY_PLACEHOLDER_USER" ] || [ -z "$reg_user" ]; then
        warn "ORACLE_REGISTRY_USER looks unset/placeholder in dbfree/.env — unauthenticated pulls will fail unless the licence for this image has been accepted anonymously."
    elif [ "$reg_pass" = "$REGISTRY_PLACEHOLDER_PASSWORD" ] || [ -z "$reg_pass" ]; then
        preflight_fail "ORACLE_REGISTRY_USER is set but ORACLE_REGISTRY_PASSWORD still looks like the .env.sample placeholder — set a real password/token in dbfree/.env."
    else
        ok "Registry credentials are set (not placeholders)"
    fi
}

check_ports_free() {
    local entry name default port
    for entry in "DB_HOST_PORT:15216" "APEX_PORT:8092" "EM_EXPRESS_HOST_PORT:5500"; do
        name="${entry%%:*}"; default="${entry##*:}"
        port="$(ini_val "$name")"; port="${port:-$default}"
        if command -v lsof &>/dev/null && lsof -iTCP:"$port" -sTCP:LISTEN &>/dev/null; then
            warn "$name ($port) is already in use by another process — either that's this stack from a previous run (fine), or pick a different port in dbfree/.env. If SQL*Net/HTTP later hangs on this port despite it appearing free, see the stuck-NAT gotcha in README.md."
        else
            ok "$name ($port) is free"
        fi
    done
}

preflight() {
    hdr "Preflight checks"
    check_docker_daemon
    check_docker_compose
    check_grealpath
    check_disk_space
    check_registry_credentials
    check_ports_free

    if [ "$PREFLIGHT_FAILURES" -gt 0 ]; then
        echo ""
        die "$PREFLIGHT_FAILURES preflight check(s) failed — fix the above and re-run."
    fi
}

# ══════════════════════════════════════════════════════════════════════════
# Docker images
# ══════════════════════════════════════════════════════════════════════════

# Arch-aware — DOCKER_IMAGE_ARM on arm64/aarch64, DOCKER_IMAGE_AMD on
# x86_64 (select_docker_image() in
# common.sh — falls back to plain DOCKER_IMAGE if neither arch key is set).
# Sets DOCKER_IMAGE and ORDS_JAVA_IMAGE for the later steps.
resolve_images() {
    DOCKER_IMAGE="$(select_docker_image)"
    ORDS_JAVA_IMAGE="$(ini_val ORDS_JAVA_IMAGE)"
    ORDS_JAVA_IMAGE="${ORDS_JAVA_IMAGE:-eclipse-temurin:21-jre-jammy}"

    [ -n "$DOCKER_IMAGE" ] || die "DOCKER_IMAGE_ARM/DOCKER_IMAGE_AMD (or DOCKER_IMAGE) not set in dbfree/.env"

    if [[ "$DOCKER_IMAGE" == *:latest ]]; then
        die "Refusing to use :latest — pin an explicit tag for DOCKER_IMAGE_ARM/DOCKER_IMAGE_AMD (see .env.sample)."
    fi
}

# Only needed when the DB image comes from Oracle's registry; other registries
# (e.g. ghcr.io) pull unauthenticated.
registry_login() {
    [[ "$DOCKER_IMAGE" == "$REGISTRY_HOST"* ]] || return 0

    local user password
    user="$(ini_val ORACLE_REGISTRY_USER)"
    password="$(ini_val ORACLE_REGISTRY_PASSWORD)"

    if [ -n "$user" ] && [ "$user" != "$REGISTRY_PLACEHOLDER_USER" ]; then
        hdr "Docker login to $REGISTRY_HOST"
        echo "$password" | docker login "$REGISTRY_HOST" -u "$user" --password-stdin \
            || die "docker login to $REGISTRY_HOST failed — check ORACLE_REGISTRY_USER/PASSWORD in dbfree/.env, and that you've accepted the licence for Database -> Free at https://container-registry.oracle.com."
        ok "Logged in to $REGISTRY_HOST"
    else
        warn "ORACLE_REGISTRY_USER not set — attempting unauthenticated pull (will fail if the licence hasn't been accepted for this image)."
    fi
}

pull_images() {
    hdr "Pulling images"
    echo "  DB image        : $DOCKER_IMAGE"
    docker pull "$DOCKER_IMAGE" \
        || die "Failed to pull $DOCKER_IMAGE. Most likely causes: (1) the licence for Database -> Free hasn't been accepted yet at https://container-registry.oracle.com (log in, search \"database/free\", accept the licence), (2) ORACLE_REGISTRY_USER/PASSWORD in dbfree/.env are wrong, or (3) this exact tag doesn't exist for your architecture — check the repo's tag list on that site to confirm."
    ok "Pulled $DOCKER_IMAGE"

    echo "  ORDS base image : $ORDS_JAVA_IMAGE"
    docker pull "$ORDS_JAVA_IMAGE" || die "Failed to pull $ORDS_JAVA_IMAGE"
    ok "Pulled $ORDS_JAVA_IMAGE"

    # Used by run-dbfree.sh -c to reliably wipe DB-owned files/dirs regardless of
    # host-vs-container uid mismatches (see run-dbfree.sh for why).
    docker pull alpine || die "Failed to pull alpine"
    ok "Pulled alpine (used by run-dbfree.sh -c for cleanup)"
}

# ══════════════════════════════════════════════════════════════════════════
# Host directories
# ══════════════════════════════════════════════════════════════════════════
prepare_host_dirs() {
    hdr "Host directories"

    local d
    for d in \
        "$(resolve_dbfree_path DB_DATA_DIR ./oradata)" \
        "$(resolve_dbfree_path ORDS_CONFIG_DIR ./ords_config)" \
        "$(resolve_dbfree_path APEX_INSTALL_DIR ./apex-install)" \
        "$(resolve_dbfree_path ORDS_INSTALL_DIR ./ords-install)"; do
        mkdir -p "$d"
        # Oracle's container images run as a fixed internal UID (commonly 54321)
        # and need to write to these bind mounts — chmod wide open here is a
        # deliberate POC-only shortcut (this repo is explicitly demo/POC scope,
        # see td-ora-utils/CLAUDE.md), not a production pattern.
        chmod 777 "$d"
        ok "Ready: $d"
    done
}

# ══════════════════════════════════════════════════════════════════════════
# APEX / ORDS downloads
# ══════════════════════════════════════════════════════════════════════════

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
    apex_cache_dir="$(ini_val APEX_CACHE_DIR)"
    apex_cache_dir="$(expand_tilde "${apex_cache_dir:-~/.cache/oracle-apex}")"
    apex_install_dir="$(resolve_dbfree_path APEX_INSTALL_DIR ./apex-install)"

    [ -n "$apex_download_url" ] || die "APEX_DOWNLOAD_URL not set in dbfree/.env"

    # Marker: a file that only exists once the real APEX distribution is extracted.
    marker="$apex_install_dir/apexins.sql"
    if [ -f "$marker" ]; then
        ok "APEX already extracted at $apex_install_dir — skipping."
        return 0
    fi

    mkdir -p "$apex_cache_dir"
    zip_path="$apex_cache_dir/apex_${apex_version}_en.zip"
    fetch_zip "APEX $apex_version" "$apex_download_url" "$zip_path" \
        "If this URL now requires an OTN login click-through, download apex_${apex_version}_en.zip manually from https://www.oracle.com/tools/downloads/apex-downloads/ and place it at $zip_path, then re-run."

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
    ords_cache_dir="$(ini_val ORDS_CACHE_DIR)"
    ords_cache_dir="$(expand_tilde "${ords_cache_dir:-~/.cache/oracle-ords}")"
    ords_install_dir="$(resolve_dbfree_path ORDS_INSTALL_DIR ./ords-install)"

    marker="$ords_install_dir/bin/ords"
    if [ -x "$marker" ]; then
        ok "ORDS already extracted at $ords_install_dir — skipping."
        return 0
    fi

    mkdir -p "$ords_cache_dir"
    zip_path="$ords_cache_dir/ords-latest.zip"
    fetch_zip "ORDS" "$ords_download_url" "$zip_path" \
        "Download the ORDS zip manually from https://www.oracle.com/database/technologies/appdev/rest.html and place it at $zip_path, then re-run."

    mkdir -p "$ords_install_dir"
    unzip -q -o "$zip_path" -d "$ords_install_dir"
    chmod +x "$ords_install_dir/bin/ords" 2>/dev/null || true

    [ -x "$marker" ] || die "Extraction completed but $marker is missing or not executable — something is off with the archive contents."
    ok "ORDS extracted to $ords_install_dir"
}

# ══════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════
main() {
    hdr "dbfree/setup-for-dbfree.sh"

    preflight
    "$SCRIPT_DIR/install-instant-client.sh"

    resolve_images
    registry_login
    pull_images

    prepare_host_dirs
    download_apex
    download_ords

    echo ""
    ok "Setup complete. Next: ./run-dbfree.sh"
}

main "$@"
