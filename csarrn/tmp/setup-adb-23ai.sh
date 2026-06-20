#!/usr/bin/env bash
# see https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-docker-container.html#GUID-1AE1DA93-AC7A-4747-BE60-CC756E9B41C9
# assumes adb-run.sh already run and container name is adb_container 
# just sets up ATP right now but ADB free container image also has ADW which this script does not setup

#### main #######

NEW_PASSWORD="Welcome_MY_ATP_123"  # could get this from env if you want to avoid declaring here
CONTAINER_NAME="adb_container"
WALLET_DIR="$HOME/myadbwallet"
export TNS_ADMIN="$WALLET_DIR"

# ── Colima memory resize ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../../adb/config.ini"
COLIMA_MEMORY=$(grep -m1 "^COLIMA_MEMORY=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*//' | tr -d ' \n\r')
COLIMA_MEMORY="${COLIMA_MEMORY:-4}"

if command -v colima &>/dev/null; then
    echo "Resizing Colima VM memory to ${COLIMA_MEMORY}GB (disk contents preserved)..."
    colima stop 2>/dev/null || true
    colima start --memory "$COLIMA_MEMORY"
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
else
    echo "WARNING: colima not found — skipping memory resize."
fi
# ─────────────────────────────────────────────────────────────────

# change the default and expired ADMIN password 
docker exec $CONTAINER_NAME abd-cli add-database --workload-type "ATP" --admin-password $NEW_PASSWORD 

# setup Wallet 
echo "Removing existing wallet at $WALLET_DIR"
rm -rf $WALLET_DIR
mkdir -p $WALLET_DIR  # create a directory if it does not exist
echo "Copy wallet from adb_container to $WALLET_DIR"
docker cp $CONTAINER_NAME:/u01/app/oracle/wallets/tls_wallet "$WALLET_DIR/tls_wallet"


printf "####################################################################\n"
printf " You need to set the TNS_ADMIN to point to the wallet \n"
printf " export TNS_ADMIN=%s \n"  "$WALLET_DIR/tls_wallet"
printf "####################################################################\n"
