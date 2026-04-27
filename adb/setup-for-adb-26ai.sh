#!/usr/bin/env bash
set -euo pipefail

cleanup() {
    echo "Cleaning up Oracle ADB setup artifacts..."

    # Stop and remove only the Oracle containers (not all Docker)
    echo "Stopping Oracle containers..."
    docker stop oracle-db ords 2>/dev/null || true
    docker rm oracle-db ords 2>/dev/null || true

    # Remove Oracle images only
    echo "Removing Oracle container images..."
    docker rmi container-registry.oracle.com/database/free:latest 2>/dev/null || true
    docker rmi container-registry.oracle.com/database/ords:latest 2>/dev/null || true

    # Remove Oracle Instant Client
    local home_dir="${SUDO_USER_HOME_DIR:-${HOME}}"
    if [[ -d "${home_dir}/oraclient" ]]; then
        echo "Removing Oracle Instant Client from ${home_dir}/oraclient..."
        rm -rf "${home_dir}/oraclient"
    fi

    # Remove APEX download and extracted files
    rm -f "${home_dir}/apex-latest.zip" 2>/dev/null || true
    if [[ -d "${home_dir}/apex" ]]; then
        echo "Removing APEX directory ${home_dir}/apex..."
        rm -rf "${home_dir}/apex"
    fi

    # Remove ORDS config and generated files
    if [[ -d "$RUN_DIR/ords_config" ]]; then
        echo "Removing ORDS config..."
        rm -rf "$RUN_DIR/ords_config"
    fi
    rm -f "$RUN_DIR/.env" 2>/dev/null || true
    rm -f "$RUN_DIR/sql-scripts/create-users.sql" 2>/dev/null || true
    rm -f "$RUN_DIR/sql-scripts/setup-ollama-ai.sql" 2>/dev/null || true

    # Remove TNS and auth config
    rm -rf "${home_dir}/auth" 2>/dev/null || true

    # Clean environment from .bashrc (entries added by install_oracle_instant_client)
    local bashrc="${home_dir}/.bashrc"
    if [[ -f "$bashrc" ]]; then
        echo "Removing Oracle environment variables from $bashrc..."
        sed -i '/export TNS_ADMIN=/d; /export ORACLE_HOME=.*oraclient/d; /export LD_LIBRARY_PATH=.*oraclient/d; /export PATH=.*oraclient/d' "$bashrc"
    fi

    echo ""
    echo "Cleanup complete. Removed: Oracle containers, images, Instant Client, APEX, ORDS config."
    echo "Docker itself was NOT removed (may be used by other services)."
    echo "Database data directory ~/db_data_dir was NOT removed. Delete manually if needed:"
    echo "  rm -rf ${home_dir}/db_data_dir"
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

    echo "Failed to start Docker after 5 attempts."
    echo "Please try sudo systemctl restart docker as this may resolve the issue"
    echo "and then run this script again."
    exit 1
}

check_docker_installed() {
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Installing Docker..."
        apt install -y docker.io
        systemctl daemon-reload
        systemctl enable docker
        systemctl restart containerd
        systemctl restart docker
    fi

    # Always ensure the invoking user is in the docker group (idempotent).
    # Group membership takes effect in new sessions; run-adb-26ai.sh handles
    # the case where the current session predates the group add via sg docker.
    if [ -n "$SUDO_USER_NAME" ] && ! id -nG "$SUDO_USER_NAME" | grep -qw docker; then
        echo "Adding $SUDO_USER_NAME to the docker group..."
        usermod -aG docker "$SUDO_USER_NAME"
        echo "Done. Docker group will be active in new login sessions."
        echo "run-adb-26ai.sh will apply it automatically in the current session."
    else
        echo "User $SUDO_USER_NAME is already in the docker group."
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
    
    if [ -n "${SUDO_UID:-}" ]; then
        SUDO_USER_NAME=$(getent passwd "$SUDO_UID" | cut -d: -f1)
        echo "The UID of the user who invoked sudo is $SUDO_UID."
        echo "The username of the user who invoked sudo is $SUDO_USER_NAME."
        SUDO_USER_HOME_DIR=$(getent passwd "$SUDO_USER_NAME" | cut -d: -f6)
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

# Function to check if the operating system is Ubuntu 22 or 24
check_os() {
    if ! lsb_release -a 2>/dev/null | grep -qE "Ubuntu (22|24)"; then
        echo "This script is intended to run on Ubuntu 22 or 24. Exiting."
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

check_and_install_packages() {
    # Check if the required packages are installed
    for package in "$@"; do
        if ! dpkg -l | grep -q "ii  $package"; then
            echo "$package is not installed. Installing $package..."
            apt install -y "$package"
        fi
    done
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
        if ! getent group "$group" > /dev/null; then
            groupadd -g "${group_ids[$group]}" "$group"
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

# Function to ensure docker compose plugin is installed
check_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "Docker Compose plugin available: $(docker compose version)"
        return
    fi
    echo "Docker Compose plugin not found. Installing docker-compose-plugin..."
    apt-get install -y docker-compose-v2
    if ! docker compose version >/dev/null 2>&1; then
        echo "Failed to install Docker Compose plugin. Exiting."
        exit 1
    fi
    echo "Docker Compose plugin installed: $(docker compose version)"
}

# Function to unzip APEX into APEX_DIR for ORDS to pick up
prepare_apex() {
    # Default to $HOME/apex if not set in config.ini — keeps large files out of the repo
    local EFFECTIVE_APEX_DIR="${APEX_DIR:-$SUDO_USER_HOME_DIR/apex}"
    local APEX_ZIP="$SUDO_USER_HOME_DIR/apex-latest.zip"
    local APEX_PARENT=$(dirname "$EFFECTIVE_APEX_DIR")

    if [ -d "$EFFECTIVE_APEX_DIR" ] && [ "$(ls -A "$EFFECTIVE_APEX_DIR" 2>/dev/null)" ]; then
        echo "APEX directory already prepared at $EFFECTIVE_APEX_DIR. Skipping."
        return
    fi

    if [ ! -f "$APEX_ZIP" ]; then
        echo "Downloading Oracle APEX (~290MB)..."
        curl -fL -C - -o "$APEX_ZIP" "https://download.oracle.com/otn_software/apex/apex-latest.zip"
        if [ $? -ne 0 ]; then
            echo "Failed to download APEX. Exiting."
            exit 1
        fi
        chown "$SUDO_USER_NAME" "$APEX_ZIP" 2>/dev/null || true
    else
        echo "Using existing APEX zip at $APEX_ZIP."
    fi

    echo "Unzipping APEX to $APEX_PARENT (will create $EFFECTIVE_APEX_DIR)..."
    mkdir -p "$APEX_PARENT"
    unzip -q -o "$APEX_ZIP" -d "$APEX_PARENT"
    if [ $? -ne 0 ] || [ ! -d "$EFFECTIVE_APEX_DIR" ]; then
        echo "Failed to unzip APEX. Exiting."
        exit 1
    fi
    chown -R "$SUDO_USER_NAME" "$EFFECTIVE_APEX_DIR" 2>/dev/null || true
    echo "APEX prepared at $EFFECTIVE_APEX_DIR."
}

# Function to create the ORDS config directory (ORDS writes its config here on first run)
create_ords_config_dir() {
    local ORDS_CONFIG_DIR="$RUN_DIR/ords_config"
    if [ ! -d "$ORDS_CONFIG_DIR" ]; then
        echo "Creating ORDS config directory at $ORDS_CONFIG_DIR..."
        mkdir -p "$ORDS_CONFIG_DIR"
        chmod 777 "$ORDS_CONFIG_DIR"  # ORDS container runs as oracle (uid 54321), needs write access
    else
        echo "ORDS config directory already exists at $ORDS_CONFIG_DIR."
    fi
}

# Oracle Container Registry login — optional.
# The database/free and database/ords images are publicly accessible without login.
# Only needed if pulls start failing (rate limit or policy change).
# Set ORACLE_REGISTRY_USER and ORACLE_REGISTRY_PASSWORD in config.ini to enable.
oracle_registry_login() {
    if [ -z "$ORACLE_REGISTRY_USER" ] || [ -z "$ORACLE_REGISTRY_PASSWORD" ]; then
        echo "Oracle Container Registry credentials not set — skipping login (not required for free-tier images)."
        return
    fi
    echo "Logging in to Oracle Container Registry as $ORACLE_REGISTRY_USER..."
    echo "$ORACLE_REGISTRY_PASSWORD" | docker login container-registry.oracle.com -u "$ORACLE_REGISTRY_USER" --password-stdin
    if [ $? -ne 0 ]; then
        echo "Docker login failed. Check credentials at https://container-registry.oracle.com"
        exit 1
    fi
    echo "Oracle Container Registry login successful."
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

    # libaio package and symlink differ between Ubuntu versions
    UBUNTU_VER=$(lsb_release -rs | cut -d. -f1)
    if [ "$UBUNTU_VER" -ge 24 ]; then
        # Ubuntu 24+: library is libaio.so.1t64; instant client needs libaio.so.1 symlink
        apt-get install -y libaio1t64
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1t64"
    else
        # Ubuntu 22: library is libaio.so.1.0.1; instant client needs libaio.so.1 symlink
        apt-get install -y libaio1
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1.0.1"
    fi
    # Ensure libaio.so.1 symlink exists and points to the correct target
    LIBAIO_LINK="/usr/lib/x86_64-linux-gnu/libaio.so.1"
    if [ ! -e "$LIBAIO_LINK" ] || [ "$(readlink "$LIBAIO_LINK")" != "$LIBAIO_TARGET" ]; then
        echo "Creating/fixing libaio.so.1 symlink -> $LIBAIO_TARGET"
        ln -sf "$LIBAIO_TARGET" "$LIBAIO_LINK"
    fi

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
        read -t 30 -p "Do you want to use the existing volume? (y/n): " choice || choice="y"
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
        docker volume create "$VOL_NAME"
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
    DEFAULT_PASSWORD=$(awk -F "=" '/^DEFAULT_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    ORACLE_REGISTRY_USER=$(awk -F "=" '/^ORACLE_REGISTRY_USER/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    ORACLE_REGISTRY_PASSWORD=$(awk -F "=" '/^ORACLE_REGISTRY_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    DOCKER_IMAGE=$(awk -F "=" '/^DOCKER_IMAGE/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    APEX_DIR=$(awk -F "=" '/^APEX_DIR/ {print $2}' "$CONFIG_FILE" | tr -d ' ')

    if [ -z "$BASIC_ZIP" ] || [ -z "$SQLPLUS_ZIP" ] || [ -z "$BASIC_URL" ] || [ -z "$SQLPLUS_URL" ] || [ -z "$INSTANT_CLIENT" ]; then
        echo "One or more Instant Client configuration values are missing in config.ini. Exiting."
        exit 1
    fi
    if [ -z "$HOSTNAME" ]; then
        echo "HOSTNAME is not set in config.ini. Exiting."
        exit 1
    fi
    if [ -z "$DEFAULT_PASSWORD" ]; then
        echo "DEFAULT_PASSWORD is not set in config.ini. Exiting."
        exit 1
    fi
    if [ -z "$DOCKER_IMAGE" ]; then
        echo "DOCKER_IMAGE is not set in config.ini. Exiting."
        exit 1
    fi
}

# Pre-flight checks — run before any system changes to catch problems early
preflight_check() {
    local warnings=0

    echo "--- Pre-flight checks ---"

    # Network reachability for Instant Client downloads
    if ! curl -s --max-time 8 -o /dev/null "https://download.oracle.com" 2>/dev/null; then
        echo "WARNING: Cannot reach download.oracle.com — Instant Client download may fail."
        warnings=$((warnings + 1))
    fi

    # Network reachability for APEX download
    if ! curl -s --max-time 8 -o /dev/null "https://download.oracle.com/otn_software/apex/" 2>/dev/null; then
        echo "WARNING: Cannot reach Oracle APEX download URL — APEX download may fail."
        warnings=$((warnings + 1))
    fi

    # Oracle Container Registry credentials are optional — images are publicly pullable.
    if [ -n "$ORACLE_REGISTRY_USER" ] && [ -n "$ORACLE_REGISTRY_PASSWORD" ]; then
        echo "Oracle Container Registry credentials configured — login will be attempted."
    fi

    # Disk space: need ~600MB for APEX zip + instant client ZIPs + unzipped content
    local home_dir="${SUDO_USER_HOME_DIR:-$HOME}"
    local avail_kb
    avail_kb=$(df "$home_dir" --output=avail 2>/dev/null | tail -1)
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 2097152 ]; then  # 2 GB in KB
        echo "WARNING: Less than 2 GB free in $home_dir — downloads may fail."
        warnings=$((warnings + 1))
    fi

    if [ "$warnings" -gt 0 ]; then
        echo "--- $warnings warning(s) noted above. Continuing... ---"
    else
        echo "--- Pre-flight checks passed ---"
    fi
}

# Function to install Python packages needed by caseweave / weave32 utility scripts.
# Includes: Oracle DB driver, image processing, face recognition, and their build deps.
# LLM inference uses local Ollama via HTTP — no extra Python packages required.
install_python_deps() {
    echo "Installing Python build dependencies for caseweave utils..."

    # System packages needed to compile dlib (required by face_recognition)
    local BUILD_PKGS=(cmake libopenblas-dev liblapack-dev python3-dev)
    for pkg in "${BUILD_PKGS[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            echo "  Installing $pkg..."
            apt-get install -y "$pkg"
        fi
    done

    # Determine pip flags — PEP 668 externally-managed envs (Ubuntu 24+)
    local PIP_FLAGS=""
    if "$PYTHON_BIN" -c "import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)" 2>/dev/null; then
        PIP_FLAGS="--break-system-packages"
    fi

    echo "Installing Python packages (as $SUDO_USER_NAME)..."
    su - "$SUDO_USER_NAME" -c "$PYTHON_BIN -m pip install $PIP_FLAGS \
        oracledb \
        Pillow \
        geopy \
        numpy \
        opencv-python-headless \
        face_recognition"

    echo "Python dependencies installed."
}

####### main code #######
SUDO_USER_NAME=""
SUDO_USER_HOME_DIR=""

TNS_ADMIN=""
ORACLE_HOME=""
ORACLE_CLIENT_DIR=""
INSTANT_CLIENT=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

############# don't change these ############
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in

# Resolve the invoking user early (needed by cleanup)
set_sudo_user

# Parse arguments before read_config so cleanup doesn't need a valid config
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

# Read configuration (only reached if not cleanup/help)
read_config

# Call the functions to perform the checks
check_root_user
check_os
preflight_check
check_and_install_packages "unzip" "curl" "git"
check_and_add_hostname
echo "sudo user is $SUDO_USER_NAME"
check_docker_installed
ensure_docker_running
oracle_os_user_setup
install_oracle_instant_client
oracle_registry_login
check_docker_compose
prepare_apex
create_ords_config_dir
install_python_deps

# Fix ownership of any files in RUN_DIR that were created as root during this or
# prior sudo runs, so the invoking user can write them without sudo going forward.
if [ -n "$SUDO_USER_NAME" ]; then
    for f in "$RUN_DIR/.env" "$RUN_DIR/ords_config" "$RUN_DIR/sql-scripts/create-users.sql"; do
        [ -e "$f" ] && chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$f" 2>/dev/null || true
    done
fi

echo
echo "OS and Docker Setup for ADB 26ai completed"
echo "Next step: run ./run-adb-26ai.sh to start the database and ORDS/APEX"