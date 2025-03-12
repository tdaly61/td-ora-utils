#!/usr/bin/env bash


cleanup() {
    echo "Cleaning up Docker and related configurations..."

    # Remove Docker containers, images, volumes, and networks
    docker system prune -a -f --volumes

    # Remove Docker package
    sudo apt-get purge -y docker.io
    sudo apt-get autoremove -y --purge docker.io

    # Remove Docker data
    rm -rf /var/lib/docker

    # Remove containerd socket file
    rm -f /run/containerd/containerd.sock

    # Remove Docker group
    if getent group docker > /dev/null; then
        sudo groupdel docker
    fi

    # Remove Docker user
    if id -u docker > /dev/null 2>&1; then
        sudo userdel -r docker
    fi

    echo "Docker and related configurations have been removed."
    exit 0
}

# Function to ensure Docker is installed and started successfully
ensure_docker_running() {
    for i in {1..5}; do
        if systemctl is-active --quiet docker; then
            echo "Docker is running."
            return
        else
            echo "Docker is not running yet. Starting Docker... (Attempt $i of 5)"
            systemctl restart containerd > /dev/null 2>&1
            systemctl restart docker > /dev/null 2>&1
            sleep 30
        fi
    done

    echo "Failed to start Docker after 5 attempts. "
    echo "Please try sudo systemctl restart docker as this may resolve the issue"
    echo " and then run this script again."
}

check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Installing Docker..."
        #apt update
        apt install -y docker.io
        
        # # Reload systemd daemon
        systemctl daemon-reload
        
        # # Start Docker service
        # if ! systemctl start docker; then
        #     echo "Failed to start Docker service. Please check the logs for more information."
        #     exit 1
        # fi
        
        # Enable Docker service to start at boot
        systemctl enable docker
        systemctl restart containerd
        systemctl restart docker
        
        # Add user to Docker group
        usermod -aG docker $SUDO_USER_NAME
        echo "Docker installed and user $SUDO_USER_NAME added to docker group. Please log out and log back in for the changes to take effect."
    fi
}

# Function to set the global variable SUDO_USER by calling the id command
set_sudo_user() {
    OS_USER=$(id -un)
    if [ -z "$OS_USER" ]; then
        echo "Failed to determine the OS user. Exiting."
        exit 1
    fi
    echo "OS user is set to $OS_USER."
    
    if [ -n "$SUDO_UID" ]; then
        SUDO_USER_NAME=$(getent passwd "$SUDO_UID" | cut -d: -f1)
        echo "The UID of the user who invoked sudo is $SUDO_UID."
        echo "The username of the user who invoked sudo is $SUDO_USER_NAME."
        SUDO_USER_HOME_DIR=$(eval echo ~$SUDO_USER_NAME)
    else
        echo "This script was not invoked using sudo."
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
        sed -i "s/^\(127\.0\.0\.1\s.*\)/\1 $HOSTNAME/" /etc/hosts
    fi
}

# Function to set up user and groups
oracle_os_user_setup() {
    echo "Setting up user and groups..."

    # Define the group IDs
    declare -A group_ids
    group_ids=(
        ["oinstall"]="54321"
        ["dba"]="54322"
        ["oper"]="54323"
        ["backupdba"]="54324"
        ["dginstall"]="54325"
        ["kmdba"]="54326"
        ["racdba"]="54330"
    )

    # Check and add groups if they do not exist
    for group in "${!group_ids[@]}"; do
        if ! getent group $group > /dev/null; then
            groupadd -g ${group_ids[$group]} $group
        fi
    done

    # Check and add user if it does not exist
    if ! id -u oracle > /dev/null 2>&1; then
        useradd -u 54321 -g oinstall -G dba,oper,oinstall,backupdba,dginstall,kmdba,racdba oracle
    fi
}


# Function to display usage
usage() {
    echo "Usage: $0 -c | -h"
    echo "Options:"
    echo "  -h  Display usage"
    exit 1
}

# Function to install Oracle Instant Client

install_oracle_instant_client() {
    
    ORACLE_CLIENT_DIR="$SUDO_USER_HOME_DIR/oraclient"
    echo "oracle_client_dir is $ORACLE_CLIENT_DIR"

    # BASIC_ZIP="instantclient-basic-linux.x64-23.6.0.24.10.zip"
    # SQLPLUS_ZIP="instantclient-sqlplus-linux.x64-23.6.0.24.10.zip"
    # BASIC_URL="https://download.oracle.com/otn_software/linux/instantclient/2360000/$BASIC_ZIP"
    # SQLPLUS_URL="https://download.oracle.com/otn_software/linux/instantclient/2360000/$SQLPLUS_ZIP"
    # INSTANT_CLIENT="instantclient_23_6"
    BASHRC_FILE="$SUDO_USER_HOME_DIR/.bashrc"

    # Ensure unzip is installed
    if ! command -v unzip &> /dev/null; then
        echo "Unzip is not installed. Installing unzip..."
        sudo apt update
        sudo apt install -y unzip
    fi

    # Install the client if not already installed
    if [ -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
        echo "Oracle Instant Client is already installed at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT."
    else 
        # Create the oraclient directory
        su - $SUDO_USER_NAME -c "mkdir -p $ORACLE_CLIENT_DIR"

        # Download the zip files
        su - $SUDO_USER_NAME -c "curl -o $ORACLE_CLIENT_DIR/$BASIC_ZIP $BASIC_URL" > /dev/null 2>&1
        su - $SUDO_USER_NAME -c "curl -o $ORACLE_CLIENT_DIR/$SQLPLUS_ZIP $SQLPLUS_URL"  > /dev/null 2>&1

        # Unzip the files
        su - $SUDO_USER_NAME -c "unzip -o $ORACLE_CLIENT_DIR/$BASIC_ZIP -d $ORACLE_CLIENT_DIR"  > /dev/null 2>&1
        su - $SUDO_USER_NAME -c "unzip -o $ORACLE_CLIENT_DIR/$SQLPLUS_ZIP -d $ORACLE_CLIENT_DIR"  > /dev/null 2>&1

        # Check if the files are unzipped
        if [ ! -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
            echo " ** Error **  Oracle instant client is not correctly installed in $ORACLE_CLIENT_DIR."
            exit 1  
        fi
    fi
    echo "ok skipped insta-client-setup" 

    # Set the environment variables
    export ORACLE_HOME="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    export LD_LIBRARY_PATH="$ORACLE_HOME"

    # libaio changed in Ubuntu 24 so need to create a symlink
    rm /usr/lib/x86_64-linux-gnu/libaio.so.1
    ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1

    # Add environment variables to .bashrc if not already present
    if ! grep -q "export TNS_ADMIN=$WALLET_DIR" "$BASHRC_FILE"; then
        echo "export TNS_ADMIN=$WALLET_DIR" >> "$BASHRC_FILE"
    fi

    if ! grep -q "export ORACLE_HOME=$ORACLE_HOME" "$BASHRC_FILE"; then
        echo "export ORACLE_HOME=$ORACLE_HOME" >> "$BASHRC_FILE"
    fi

    if ! grep -q "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH" "$BASHRC_FILE"; then
        echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >> "$BASHRC_FILE"
    fi

    if ! grep -q "export PATH=$ORACLE_HOME:\$PATH" "$BASHRC_FILE"; then
        echo "export PATH=$ORACLE_HOME:\$PATH" >> "$BASHRC_FILE"
    fi

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

# # Function to create a Docker volume
create_docker_volume() {
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
        # create a local volume
        docker volume create $VOL_NAME
        change_volume_ownership
    fi
}


# Function to read configuration from config.ini
read_config() {
    CONFIG_FILE="$RUN_DIR/config.ini"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file config.ini not found in $RUN_DIR. Exiting."
        exit 1
    fi

    BASIC_ZIP=$(awk -F "=" '/^BASIC_ZIP/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    SQLPLUS_ZIP=$(awk -F "=" '/^SQLPLUS_ZIP/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    BASIC_URL=$(awk -F "=" '/^BASIC_URL/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    SQLPLUS_URL=$(awk -F "=" '/^SQLPLUS_URL/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    INSTANT_CLIENT=$(awk -F "=" '/^INSTANT_CLIENT/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    HOSTNAME=$(awk -F "=" '/^HOSTNAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    VOL_NAME=$(awk -F "=" '/^VOL_NAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    DEFAULT_PASSWORD=$(awk -F "=" '/^DEFAULT_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' ')


    if [ -z "$BASIC_ZIP" ] || [ -z "$SQLPLUS_ZIP" ] || [ -z "$BASIC_URL" ] || [ -z "$SQLPLUS_URL" ] || [ -z "$INSTANT_CLIENT" ]; then
        echo "One or more configuration values are missing in config.ini. Exiting."
        exit 1
    fi
}

####### main code #######
SUDO_USER_NAME=""
SUDO_USER_HOME_DIR=""

TNS_ADMIN=""
ORACLE_HOME=""
ORACLE_CLIENT_DIR=""
INSTANT_CLIENT=""

############# don't change these ############
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in 

# Read configuration
read_config

set_sudo_user
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
check_root_user
check_os
check_and_add_hostname
echo "sudo user is $SUDO_USER_NAME"
check_docker_installed
ensure_docker_running
oracle_os_user_setup
install_oracle_instant_client
#create_docker_volume

echo 
echo "OS and Docker Setup for ADB 23ai completed "