#!/usr/bin/env bash

# Function to ensure Docker is installed
check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Installing Docker..."
        sudo apt update
        sudo apt install -y docker.io
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
        echo "Docker installed and user $USER added to docker group. Please log out and log back in for the changes to take effect."
        exit 0
    fi
}

# Function to set the global variable OS_USER by calling the id command
set_os_user() {
    OS_USER=$(id -un)
    if [ -z "$OS_USER" ]; then
        echo "Failed to determine the OS user. Exiting."
        exit 1
    fi
    echo "OS user is set to $OS_USER."
}



# Function to check if the script is being run as root
check_root_user() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root. Please run as root or use sudo."
        exit 1
    fi
}

# Function to check if the operating system is Ubuntu 24
check_os() {
    if ! lsb_release -a 2>/dev/null | grep -q "Ubuntu 24"; then
        echo "This script is intended to run on Ubuntu 24. Exiting."
        exit 1
    fi
}

# Function to check if the hostname exists in /etc/hosts
check_and_add_hostname() {
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        echo "$HOSTNAME not found in /etc/hosts. Adding it."
        sudo perl -pi -e 's/^(127\.0\.0\.1\s+.*)/\1 $ENV{HOSTNAME}/' /etc/hosts
    fi
}

# Function to set up user and groups
user_setup() {
    echo "Setting up user and groups..."

    # Check and add groups if they do not exist
    for group in oinstall dba oper backupdba dgdba kmdba racdba; do
        if ! getent group $group > /dev/null; then
            sudo groupadd -g $(id -g $group 2>/dev/null || echo "5432${group: -1}") $group
        else
            echo "Group $group already exists. Skipping."
        fi
    done

    # Check and add user if it does not exist
    if ! id -u oracle > /dev/null 2>&1; then
        sudo useradd -u 54321 -g oinstall -G dba,oper,backupdba,dgdba,kmdba,racdba oracle
    else
        echo "User oracle already exists. Skipping."
    fi
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
    echo "Usage: $0 -u <user>"
    exit 1
}

# Function to determine the volume path and change ownership
change_volume_ownership() {
    VOL_PATH=$(docker volume inspect "$VOL_NAME" --format '{{ .Mountpoint }}')
    if [ -z "$VOL_PATH" ]; then
        echo "Failed to determine the volume path for $VOL_NAME. Exiting."
        exit 1
    fi
    echo "Changing ownership of volume path $VOL_PATH to user oracle and group oinstall."
    sudo chown -R oracle:oinstall "$VOL_PATH"
}

# Function to create a Docker volume
create_docker_volume() {
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
        # create a local volume
        docker volume create $VOL_NAME
        change_volume_ownership
    fi
}

# run adb docker container 
# this script will run the ADB container with the required ports exposed
# now run ADB with the volume mounted as /u01/data
function run_adb() {
    echo "Running ADB using the container image $DOCKER_IMAGE" 
    su $OS_USER -c "docker run -d \
    -p 1521:1522 \
    -p 1522:1522 \
    -p 8443:8443 \
    -p 27017:27017 \
    -e WORKLOAD_TYPE='ATP' \
    -e WALLET_PASSWORD='$DEFAULT_PASSWORD' \
    -e ADMIN_PASSWORD='$DEFAULT_PASSWORD' \
    --hostname '$HOSTNAME' \
    --cap-add SYS_ADMIN \
    --device /dev/fuse \
    --volume '$VOL_NAME':/u01/data \
    --name '$CONTAINER_NAME' \
    '$DOCKER_IMAGE' "

    # --volume '$VOL_NAME':/u01/data \
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
get_models() {
    MODEL_PATH="/tmp/all-MiniLM-L6-v2.onnx"
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Downloading ONNX model from $ONNX_MODEL_URL..."
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

####### main code #######
# to use a remote hostname this needs to be a valid FQDN or in /etc/hosts so that certs are generated correctly 
# e.g. myhost.local must be in /etc/hosts on the remote 
# also make sure port 8443 is open just 443 is not sufficient (at least on azure cloud)

#########  Modify these global variables for your deployment ########
HOSTNAME="fu8.local" 

######### These should not need to be changed ########
OS_USER=""
VOL_NAME="adb_container_vol" 
DEFAULT_PASSWORD="Welcome_MY_ATP_123"
CONTAINER_NAME="adb-free"
DOCKER_IMAGE="container-registry.oracle.com/database/adb-free:latest-23ai"
ONNX_MODEL_URL="https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/94ea1512acaefbfe2e255b2d2ea4bf0d9d7b3dc3/onnx/model.onnx"

# Parse arguments
while getopts "h" opt; do
    case ${opt} in
        h )
            usage
            ;;
        \? )
            usage
            ;;
    esac
done

# Check if user argument is provided
if [ -z "$USER" ]; then
    usage
fi

# Call the functions to perform the checks
check_root_user
set_os_user
check_os
check_docker_installed
check_and_add_hostname
user_setup
check_existing_container
create_docker_volume
run_adb
wait_for_container_healthy 600
# now we need to configure the database and add the AI models 
get_models


echo "to see status of deployment use .." 
echo "docker logs -f $CONTAINER_NAME "
echo " " 
echo "Access APEX and SQlDeveloper Web use .." 
echo "https://$HOSTNAME:8443/ords/_/landing"