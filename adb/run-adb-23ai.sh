#!/usr/bin/env bash

# Function to clean up Docker resources
cleanup() {
    echo "Stopping and removing the Docker container $CONTAINER_NAME..."
    docker stop $CONTAINER_NAME >> /dev/null 2>&1
    docker rm $CONTAINER_NAME >> /dev/null 2>&1

    echo "Do you want to remove the database data directory $HOME/db_data_dir? (y/n): "
    read choice
    case "$choice" in 
        y|Y ) 
            echo "Removing database data directory $HOME/db_data_dir..."
            rm -rf "$HOME/db_data_dir"
            ;;
        n|N ) 
            echo "Skipping database data directory removal."
            ;;
        * ) 
            echo "Invalid choice. Skipping database data directory removal."
            ;;
    esac
    # echo "Do you want to remove the Docker volume $VOL_NAME? (y/n): "
    # read choice
    # case "$choice" in 
    #     y|Y ) 
    #         echo "Removing Docker volume $VOL_NAME..."
    #         docker volume rm $VOL_NAME
    #         docker volume ls 
    #         ;;
    #     n|N ) 
    #         echo "Skipping volume removal."
    #         ;;
    #     * ) 
    #         echo "Invalid choice. Skipping volume removal."
    #         ;;
    # esac
    # echo "Do you want to remove the Docker image $DOCKER_IMAGE? (y/n): "
    # read choice
    # case "$choice" in 
    #     y|Y ) 
    #         echo "Removing Docker image $DOCKER_IMAGE..."
    #         docker rmi $DOCKER_IMAGE
    #         docker images 
    #         ;;
    #     n|N ) 
    #         echo "Skipping image removal."
    #         ;;
    #     * ) 
    #         echo "Invalid choice. Skipping image removal."
    #         ;;
    # esac
    exit 0
}


# Function to check if a Docker container with the given name exists
check_existing_container() {
    if [ "$(docker ps -aq -f name=$CONTAINER_NAME)" ]; then
        echo "A Docker container with the name $CONTAINER_NAME already exists."
        echo "Please shut down and remove the existing container using the following commands:"
        echo "docker stop $CONTAINER_NAME"
        echo "docker rm $CONTAINER_NAME"
        exit 1
    fi
}

# Function to display usage
usage() {
    echo "Usage: $0 -c | -h"
    echo "Options:"
    echo "  -c  Cleanup Docker resources"
    echo "  -h  Display usage"
    exit 1
}

create_db_data_dir() { 
    if [ ! -d "$HOME/db_data_dir" ]; then
        echo "Creating db_data_dir directory at $HOME/db_data_dir..."
        mkdir -p "$HOME/db_data_dir"
        chmod 777 "$HOME/db_data_dir"
    fi
}


# # Function to create a Docker volume
create_docker_volume() {
    LOCAL_VOL_DIR="$HOME/dbvol"
    if [ ! -d "$LOCAL_VOL_DIR" ]; then
        echo "Creating local volume directory at $LOCAL_VOL_DIR..."
        mkdir -p "$LOCAL_VOL_DIR"
    fi

    echo "Creating Docker volume $VOL_NAME..."
    if docker volume inspect "$VOL_NAME" >/dev/null 2>&1; then
        echo "Warning: Volume '$VOL_NAME' already exists."
        read -p "Do you want to use the existing volume? (y/n): " choice
        case "$choice" in 
            y|Y ) 
                echo "Using existing volume '$VOL_NAME'."
                ;;
            n|N ) 
                echo "Exiting. Please remove the existing volume with 'docker volume rm $VOL_NAME' before trying again."
                exit 1
                ;;
            * ) 
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
    else
        docker volume create --driver local --opt type=none --opt device="$LOCAL_VOL_DIR" --opt o=bind "$VOL_NAME"
        docker run --rm -v "$VOL_NAME":/mnt busybox sh -c "addgroup -S oinstall && adduser -S oracle -G oinstall && chown -R oracle:oinstall /mnt"
    fi
}
# create_docker_volume() {
#     LOCAL_VOL_DIR="$HOME/dbvol"
#     if [ ! -d "$LOCAL_VOL_DIR" ]; then
#         echo "Creating local volume directory at $LOCAL_VOL_DIR..."
#         mkdir -p "$LOCAL_VOL_DIR"
#     fi

#     echo "Creating Docker volume $VOL_NAME..."
#     if docker volume inspect "$VOL_NAME" >/dev/null 2>&1; then
#         echo "Warning: Volume '$VOL_NAME' already exists."
#         read -p "Do you want to use the existing volume? (y/n): " choice
#         case "$choice" in 
#             y|Y ) 
#                 echo "Using existing volume '$VOL_NAME'."
#                 ;;
#             n|N ) 
#                 echo "Exiting. Please remove the existing volume with 'docker volume rm $VOL_NAME' before trying again."
#                 exit 1
#                 ;;
#             * ) 
#                 echo "Invalid choice. Exiting."
#                 exit 1
#                 ;;
#         esac
#     else

#         # create a local volume
#         docker volume create $VOL_NAME
#         #docker volume create --driver local --opt type=none --opt device="$LOCAL_VOL_DIR" --opt o=bind "$VOL_NAME"
#         #change_volume_ownership
#         # Run a Docker container to set the ownership
#         #docker run --rm -v "$VOL_NAME":/mnt busybox sh -c "addgroup -S oinstall && adduser -S oracle -G oinstall && chown -R oracle:oinstall /mnt"
#         docker inspect $VOL_NAME
#     fi

# }

# run adb docker container 
# this script will run the ADB container with the required ports exposed
# now run ADB with the volume mounted as /u01/data
HOSTNAME="fu8.local"
VOL_NAME="adb_container_vol"

function run_adb() {
    echo "Running ADB using image $DOCKER_IMAGE & DB data directory $HOME/db_data_dir" 
    docker run -d \
    -p 1521:1522 \
    -p 1522:1522 \
    -p 8443:8443 \
    -p 27017:27017 \
    -e WORKLOAD_TYPE='ATP' \
    -e WALLET_PASSWORD=$DEFAULT_PASSWORD \
    -e ADMIN_PASSWORD=$DEFAULT_PASSWORD \
    --hostname $HOSTNAME \
    --cap-add SYS_ADMIN \
    --device /dev/fuse \
    --volume "$HOME/db_data_dir":/u01/data \
    --name adb-free \
    "$DOCKER_IMAGE"

    #     --security-opt apparmor:unconfined \
    #--volume "$HOME/db_data_dir":/u01/data \
    # --volume "$VOL_NAME":/u01/data \
    # note to override the entrypoint for debugging replace the last 2 lines of the docker run with the 2 following lines 
    #      --entrypoint '/bin/bash' \
    #      $DOCKER_IMAGE -c 'sleep 3600' "
}  

# Function to print the elapsed time in a human-readable format
print_elapsed_time() {
    local SECONDS=$1
    local HOURS=$((SECONDS / 3600))
    local MINUTES=$(( (SECONDS % 3600) / 60 ))
    local SECONDS=$((SECONDS % 60))
    printf "%02d:%02d:%02d\n" $HOURS $MINUTES $SECONDS
}

# Function to wait for the container to be in running and healthy state with timeout
wait_for_container_healthy() {
    TIMEOUT=$1
    echo "Waiting for [ $TIMEOUT ] secs the container $CONTAINER_NAME to be in a running and healthy state..."
    
    START_TIME=$(date +%s)
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
        
        if [ "$ELAPSED_TIME" -ge "$TIMEOUT" ]; then
            echo "Timeout of $TIMEOUT seconds reached. Exiting."
            exit 1
        fi
        
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME")
        if [ "$STATUS" == "healthy" ]; then
            echo "Container $CONTAINER_NAME is running and healthy."
            break
        elif [ "$STATUS" == "unhealthy" ]; then
            echo "Container $CONTAINER_NAME is unhealthy. Exiting."
            exit 1
        else
            echo "Container $CONTAINER_NAME is not yet healthy. Current status: $STATUS. Waiting..."
            echo "Elapsed time: $(print_elapsed_time $ELAPSED_TIME)"
            sleep 15
        fi
    done
    
    TOTAL_TIME=$((CURRENT_TIME - START_TIME))
    echo "Total time taken: $(print_elapsed_time $TOTAL_TIME)"
}


# Function to download the ONNX model if not already downloaded
get_model() {
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Downloading ONNX model from $ONNX_MODEL_URL... to $MODEL_PATH"
        curl -o "$MODEL_PATH" "$ONNX_MODEL_URL"
        if [ $? -ne 0 ]; then
            echo "Failed to download the ONNX model. Exiting."
            exit 1
        fi
        echo "ONNX model downloaded and saved to $MODEL_PATH."
    else
        echo "ONNX model already exists at $MODEL_PATH. Skipping download."
    fi
}

configure_sql_access() {
    echo "Configuring SQL access..."
    # change the default and expired ADMIN password 
    #docker exec $CONTAINER_NAME /u01/scripts/change_expired_password.sh MY_ATP admin Welcome_MY_ATP_1234 $DEFAULT_PASSWORD
    #SUDO_USER_HOME_DIR=$(eval echo ~$SUDO_USER_NAME)
    AUTH_DIR="$HOME/auth"
    WALLET_DIR="$AUTH_DIR/tls_wallet"

    rm -rf $AUTH_DIR
    echo "Creating auth directory at $AUTH_DIR."
    mkdir -p $AUTH_DIR
    docker cp adb-free:/u01/app/oracle/wallets/tls_wallet/ $AUTH_DIR
}

# Function to run SQL command and set DPDUMP_DIR
set_dpdump_dir() {
    echo "oracle_client_dir is $ORACLE_CLIENT_DIR"
    echo "instant_client is $INSTANT_CLIENT"
    echo "LD_LIBRARY_PATH is $LD_LIBRARY_PATH"
    echo "TNS_ADMIN is $TNS_ADMIN"
    echo "Running SQL command to get DATA_PUMP_DIR..."
    SQL_OUTPUT=$(echo "SELECT directory_path FROM dba_directories WHERE directory_name='DATA_PUMP_DIR';" | \
                  $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus -s admin/$DEFAULT_PASSWORD@myatp_high)
    echo $SQL_OUTPUT

    DPDUMP_DIR=$(echo "$SQL_OUTPUT" | grep "^/u01/dbfs" | awk '{print $1}')
    
    if [ -z "$DPDUMP_DIR" ]; then
        echo "Failed to retrieve DATA_PUMP_DIR. Exiting."
        exit 1
    fi
    echo "DATA_PUMP_DIR is set to $DPDUMP_DIR."
}

# Function to run a SQL file
run_sql_file() {
    local sql_file="$1"
    local user="$2"
    local sql_output

    if [ ! -f "$sql_file" ]; then
        echo "SQL file $sql_file does not exist. Exiting."
        return 1
    fi
    echo "Running SQL file $sql_file..."
    $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus -s $user/$DEFAULT_PASSWORD@myatp_high @$sql_file
    if [ $? -ne 0 ]; then
        echo "Failed to execute SQL file $sql_file. Exiting."
        return 1
    fi
    echo "SQL file $sql_file executed successfully."
    #echo "$sql_output"
}

# Function to read configuration from config.ini
read_config() {
    CONFIG_FILE="$RUN_DIR/config.ini"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file config.ini not found in $RUN_DIR. Exiting."
        exit 1
    fi
    SQLPLUS_URL=$(awk -F "=" '/^SQLPLUS_URL/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    INSTANT_CLIENT=$(awk -F "=" '/^INSTANT_CLIENT/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    HOSTNAME=$(awk -F "=" '/^HOSTNAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    #VOL_NAME=$(awk -F "=" '/^VOL_NAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    DEFAULT_PASSWORD=$(awk -F "=" '/^DEFAULT_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' '  | tr -d '\n' | tr -d '\r')
    CONTAINER_NAME=$(awk -F "=" '/^CONTAINER_NAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    DOCKER_IMAGE=$(awk -F "=" '/^DOCKER_IMAGE/ {print $2}' "$CONFIG_FILE" | tr -d ' '  )
    ONNX_MODEL_URL=$(awk -F "=" '/^ONNX_MODEL_URL/ {print $2}' "$CONFIG_FILE" | tr -d ' '  )

    if [ -z "$SQLPLUS_URL" ] || [ -z "$INSTANT_CLIENT" ] || [ -z "$HOSTNAME" ] || [ -z "$VOL_NAME" ] || [ -z "$DEFAULT_PASSWORD" ] || [ -z "$CONTAINER_NAME" ] || [ -z "$DOCKER_IMAGE" ]; then
        echo "One or more configuration values are missing in config.ini. Exiting."
        exit 1
    fi
}


####### main code #######
WALLET_DIR=""
TNS_ADMIN=""
ORACLE_CLIENT_DIR="$HOME/oraclient"
MODEL_PATH="$HOME/model.onnx"
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in 

# Read configuration
read_config
echo $DEFAULT_PASSWORD

# Parse arguments
while getopts "hc" opt; do
    case ${opt} in
        h )
            usage
            ;;
        c )
            cleanup
            ;;
        \? )
            usage
            ;;
    esac
done

# Call the functions to perform the checks
#create_docker_volume
check_existing_container
create_db_data_dir
run_adb
wait_for_container_healthy 1800
get_model

sleep 30 

configure_sql_access
export TNS_ADMIN="$WALLET_DIR"
echo "TNS_ADMIN is $TNS_ADMIN"

#set_dpdump_dir
DBFS_DIR=`docker exec -it adb-free ls -ltr /u01/dbfs | tail -1 | awk '{print $9}' | tr -d "\r"` 
echo "DBFS_DIR is $DBFS_DIR"
DATA_PUMP_DIR="/u01/dbfs/${DBFS_DIR}/data/dpdump"
echo "DATA_PUMP_DIR is $DATA_PUMP_DIR"
docker exec -it adb-free ls -l $DPDUMP_DIR
echo "DPDUMP_DIR is $DPDUMP_DIR"
docker exec -it adb-free ls -l $DPDUMP_DIR
echo "====" 

# copy onnx model into the container
docker cp "$MODEL_PATH" "adb-free:/tmp/model.onnx"
docker exec -it adb-free cp '/tmp/model.onnx' "$DATA_PUMP_DIR/model.onnx"
# echo "dump dir file results" 
# docker exec -it adb-free ls -l /u01/data
#docker exec -it adb-free mount 


#run_sql_file "$RUN_DIR/test.sql"
# ADD SQL-SETUP HERE 
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" admin 
run_sql_file "$RUN_DIR/sql-scripts/vector-setup.sql"  admin


echo "Notes ..." 
echo "1. to see database status use docker logs -f $CONTAINER_NAME "
echo "2. this deployment is NOT secure it is intended for Demo and POC use only" 
echo "3. Access APEX and SQlDeveloper https://$HOSTNAME:8443/ords/_/landing"
echo "4. SQLplus Login via $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus admin/$DEFAULT_PASSWORD@myatp_high"

