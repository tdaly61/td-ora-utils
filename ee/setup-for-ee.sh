#!/usr/bin/env bash
# setup-for-ee.sh — one-time (idempotent) host prep for the ee/ POC stack:
# registry login, image pull, host directories. Does not touch adb/ or its
# running container.
#
# Usage: ./setup-for-ee.sh

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

hdr "ee/setup-for-ee.sh"

REGISTRY_USER="$(ini_val ORACLE_REGISTRY_USER)"
REGISTRY_PASSWORD="$(ini_val ORACLE_REGISTRY_PASSWORD)"
DOCKER_IMAGE="$(ini_val DOCKER_IMAGE)"
ORDS_JAVA_IMAGE="$(ini_val ORDS_JAVA_IMAGE)"; ORDS_JAVA_IMAGE="${ORDS_JAVA_IMAGE:-eclipse-temurin:21-jre-jammy}"

[ -n "$DOCKER_IMAGE" ] || die "DOCKER_IMAGE not set in ee/.env"

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

# Used by run-ee.sh -c to reliably wipe DB-owned files/dirs regardless of
# host-vs-container uid mismatches (see run-ee.sh for why).
docker pull alpine || die "Failed to pull alpine"
ok "Pulled alpine (used by run-ee.sh -c for cleanup)"

hdr "Host directories"
DB_DATA_DIR="$(resolve_ee_path DB_DATA_DIR ./oradata)"
ORDS_CONFIG_DIR="$(resolve_ee_path ORDS_CONFIG_DIR ./ords_config)"
APEX_INSTALL_DIR="$(resolve_ee_path APEX_INSTALL_DIR ./apex-install)"
ORDS_INSTALL_DIR="$(resolve_ee_path ORDS_INSTALL_DIR ./ords-install)"

for d in "$DB_DATA_DIR" "$ORDS_CONFIG_DIR" "$APEX_INSTALL_DIR" "$ORDS_INSTALL_DIR"; do
    mkdir -p "$d"
    # Oracle's container images run as a fixed internal UID (commonly 54321)
    # and need to write to these bind mounts — chmod wide open here is a
    # deliberate POC-only shortcut (this repo is explicitly demo/POC scope,
    # see td-ora-utils/CLAUDE.md), not a production pattern.
    chmod 777 "$d"
    ok "Ready: $d"
done

echo ""
ok "Setup complete. Next: ./download-apex.sh && ./download-ords.sh, then ./run-ee.sh"
