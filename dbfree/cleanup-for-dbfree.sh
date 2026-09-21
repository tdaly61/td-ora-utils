#!/usr/bin/env bash
# cleanup-for-dbfree.sh — mirror of setup-for-dbfree.sh: undoes what that
# script set up. Always stops/removes the dbfree/ stack's containers;
# optionally also removes the Docker images setup-for-dbfree.sh pulled.
#
# Does NOT touch host data directories (oradata/, ords_config/) or the
# extracted APEX/ORDS distributions — use run-dbfree.sh -c for a full state
# wipe of the running stack.
#
# Usage:
#   ./cleanup-for-dbfree.sh       Stop all running dbfree containers
#   ./cleanup-for-dbfree.sh -r    Also remove the pulled Docker images
#   ./cleanup-for-dbfree.sh -h    Show this help

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

REMOVE_IMAGES=0
while getopts ":rh" opt; do
    case $opt in
        r) REMOVE_IMAGES=1 ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//; /^!/d'; exit 0 ;;
        \?) echo "ERROR: Unknown option -$OPTARG"; exit 1 ;;
    esac
done

hdr "dbfree/cleanup-for-dbfree.sh"

cd "$DBFREE_DIR"

hdr "Stopping dbfree containers"
docker compose down --remove-orphans || true
ok "Containers stopped"

if [ "$REMOVE_IMAGES" -eq 1 ]; then
    hdr "Removing pulled images"
    DOCKER_IMAGE="$(select_docker_image)"
    ORDS_JAVA_IMAGE="$(ini_val ORDS_JAVA_IMAGE)"; ORDS_JAVA_IMAGE="${ORDS_JAVA_IMAGE:-eclipse-temurin:21-jre-jammy}"

    [ -n "$DOCKER_IMAGE" ] && docker rmi "$DOCKER_IMAGE" 2>/dev/null || true
    [ -n "$ORDS_JAVA_IMAGE" ] && docker rmi "$ORDS_JAVA_IMAGE" 2>/dev/null || true
    # alpine is pulled by setup-for-dbfree.sh solely for run-dbfree.sh -c's
    # cleanup use — remove it here too so -r fully mirrors setup's pulls.
    docker rmi alpine 2>/dev/null || true
    ok "Removed pulled images (where present)"
fi

echo ""
ok "Cleanup complete."
[ "$REMOVE_IMAGES" -eq 0 ] && echo "  (images left in place — re-run with -r to remove them too)"
