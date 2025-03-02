#!/usr/bin/env bash
# see https://docs.oracle.com/en/cloud/paas/autonomous-database/serverless/adbsb/autonomous-docker-container.html#GUID-1AE1DA93-AC7A-4747-BE60-CC756E9B41C9
# assumes adb-run.sh already run and container name is adb_container 
# just sets up ATP right now but ADB free container image also has ADW which this script does not setup

#### main #######

NEW_PASSWORD="Welcome_MY_ATP_123"  # could get this from env if you want to avoid declaring here
CONTAINER_NAME="adb_container"
WALLET_DIR="$HOME/myadbwallet"
export TNS_ADMIN="$WALLET_DIR"

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
