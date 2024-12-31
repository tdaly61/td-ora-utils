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
        su - $USER -c "docker volume create $VOL_NAME"
    fi
}

# run adb docker container 
# this script will run the ADB container with the required ports exposed
# now run ADB with the volume mounted as /u01/data
function run_adb() {
    echo "USER is $USER"

    echo "Running ADB using the container image container-registry.oracle.com/database/adb-free:latest-23ai" 
    su - $USER -c "docker run -d \
    -p 1521:1522 \
    -p 1522:1522 \
    -p 8443:8443 \
    -p 27017:27017 \
    -e WORKLOAD_TYPE='ATP' \
    -e WALLET_PASSWORD='$DEFAUT_PASSWORD' \
    -e ADMIN_PASSWORD='$DEFAUT_PASSWORD' \
    --hostname '$HOSTNAME' \
    --cap-add SYS_ADMIN \
    --device /dev/fuse \
    --name '$CONTAINER_NAME' \
     $DOCKER_IMAGE "

    # --volume '$VOL_NAME':/u01/data \
    # note to override the entrypint for debugging replace the last 2 lines of the docker run with the 2 following lines 
    #      --entrypoint '/bin/bash' \
    #      $DOCKER_IMAGE -c 'sleep 3600' "
}  

####### main code #######
# to use a remote hostname this needs to be a valid FQDN or in /etc/hosts so that certs are generated correctly 
# e.g. myhost.local must be in /etc/hosts on the remote 
# also make sure port 8443 is open just 443 is not sufficient (at least on azure cloud)

#########  Modify these global variables for your deployment ########
HOSTNAME="fu8.local" 

######### These should not need to be changed ########
VOL_NAME="adb_container_vol" 
DEFAUT_PASSWORD="Welcome_MY_ATP_123"
CONTAINER_NAME="adb-free"
DOCKER_IMAGE="container-registry.oracle.com/database/adb-free:latest-23ai"

# Parse arguments
while getopts "u:h" opt; do
    case ${opt} in
        u )
            USER=$OPTARG
            ;;
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
check_os
check_docker_installed
check_and_add_hostname
check_existing_container
create_docker_volume
run_adb

echo "to see status of deployment use .." 
echo "docker logs -f $CONTAINER_NAME "
echo "" 
echo "Access APEX and SQlDeveloper Web use .." 
echo "https://$HOSTNAME:8443/ords/_/landing