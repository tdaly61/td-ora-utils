#!/usr/bin/env bash
<<<<<<< HEAD
set -euo pipefail
=======

# ─────────────────────────────────────────────────────────────────
# Platform detection — runs first; everything else dispatches on PLATFORM/ARCH
# ─────────────────────────────────────────────────────────────────
detect_platform() {
    case "$(uname -s)" in
        Linux*)  PLATFORM=linux ;;
        Darwin*) PLATFORM=darwin ;;
        *) echo "Unsupported platform: $(uname -s). Exiting."; exit 1 ;;
    esac
    ARCH=$(uname -m)   # x86_64 | arm64 | aarch64
    echo "Detected platform: $PLATFORM / $ARCH"
}
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)

# Read a single KEY=VALUE entry from CONFIG_FILE by exact key name.
# Handles values containing '=' (e.g. URLs). Strips surrounding whitespace.
ini_val() {
    local key="$1"
    grep -m1 "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d ' \n\r'
}

# ─────────────────────────────────────────────────────────────────
# Mac Docker environment fix — call once before any docker commands.
# Handles two common Mac multi-runtime issues:
#   1. Active context points to a missing socket (e.g. OrbStack uninstalled)
#      → finds the first context whose socket exists and switches to it.
#   2. Docker CLI is newer than the server (API version too new)
#      → reads the max supported version from the error and exports
#        DOCKER_API_VERSION so all subsequent docker calls use it.
# ─────────────────────────────────────────────────────────────────
_resolve_docker_mac() {
    local err
    err=$(docker info 2>&1)

    # Fix 1: socket missing for the active context → find a working one
    if echo "$err" | grep -qE "no such file or directory|cannot connect|connection refused"; then
        local ctx
        for ctx in desktop-linux default orbstack; do
            if docker context use "$ctx" &>/dev/null 2>&1; then
                err=$(docker info 2>&1)
                if ! echo "$err" | grep -qE "no such file or directory|cannot connect|connection refused"; then
                    echo "Switched Docker context to '$ctx' (previous context socket was missing)."
                    break
                fi
            fi
        done
    fi

    # Fix 2: CLI API version too new for the server → pin DOCKER_API_VERSION
    if echo "$err" | grep -q "client version.*too new"; then
        local max_ver
        max_ver=$(echo "$err" | grep -oE "Maximum supported API version is [0-9.]+" | grep -oE "[0-9.]+$")
        if [ -n "$max_ver" ]; then
            echo "Docker CLI/server API version mismatch — pinning DOCKER_API_VERSION=$max_ver"
            export DOCKER_API_VERSION="$max_ver"
        fi
    fi
}

# Available disk space in KB for a given path (cross-platform)
avail_kb_for_dir() {
    local dir="$1"
    if [ "$PLATFORM" = "darwin" ]; then
        df -k "$dir" 2>/dev/null | awk 'NR==2 {print $4}'
    else
        df "$dir" --output=avail 2>/dev/null | tail -1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────
cleanup() {
<<<<<<< HEAD
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
=======
    echo "Cleaning up Docker and related configurations..."
    docker system prune -a -f --volumes

    if [ "$PLATFORM" = "linux" ]; then
        sudo apt-get purge -y docker.io
        sudo apt-get autoremove -y --purge docker.io
        umount /var/lib/docker > /dev/null 2>&1
        rm -rf /var/lib/docker
        rm -f /run/containerd/containerd.sock
        if getent group docker > /dev/null; then
            sudo groupdel docker
        fi
        if id -u docker > /dev/null 2>&1; then
            sudo userdel -r docker
        fi
        echo "Docker and related configurations have been removed."
    else
        echo "Docker resources cleaned. To fully remove Docker Desktop, uninstall it manually via Applications."
    fi
    exit 0
}

# ─────────────────────────────────────────────────────────────────
# OS checks and user resolution
# ─────────────────────────────────────────────────────────────────
check_root_user() {
    if [ "$PLATFORM" = "darwin" ]; then
        return   # Docker Desktop on Mac runs as the current user; no root required
    fi
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root. Please run as root or use sudo."
        exit 1
    fi
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
}

check_os() {
    if [ "$PLATFORM" = "linux" ]; then
        if ! lsb_release -a 2>/dev/null | grep -qE "Ubuntu (22|24)"; then
            echo "This script is intended to run on Ubuntu 22 or 24. Exiting."
            exit 1
        fi
    fi
    # macOS: any version that supports Docker Desktop is accepted
}

set_sudo_user() {
    if [ "$PLATFORM" = "darwin" ]; then
        SUDO_USER_NAME="$USER"
        SUDO_USER_HOME_DIR="$HOME"
        echo "Mac user: $SUDO_USER_NAME (home: $SUDO_USER_HOME_DIR)"
        return
    fi

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

check_and_add_hostname() {
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        echo "$HOSTNAME not found in /etc/hosts. Adding it."
        if [ "$PLATFORM" = "darwin" ]; then
            sudo sed -i '' "s/^\(127\.0\.0\.1[[:space:]].*\)/\1 $HOSTNAME/" /etc/hosts
        else
            sed -i "s/^\(127\.0\.0\.1\s.*\)/\1 $HOSTNAME/" /etc/hosts
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────
# Package management — Linux only (Mac ships curl/git/unzip; brew for extras)
# ─────────────────────────────────────────────────────────────────
check_and_install_packages() {
    if [ "$PLATFORM" = "darwin" ]; then
        for pkg in "$@"; do
            if ! command -v "$pkg" &>/dev/null; then
                echo "WARNING: $pkg not found. Install via Homebrew: brew install $pkg"
            fi
        done
        return
    fi
    for package in "$@"; do
        if ! dpkg -l | grep -q "ii  $package"; then
            echo "$package is not installed. Installing $package..."
            apt install -y "$package"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────
# Docker installation and startup — platform-specific
# ─────────────────────────────────────────────────────────────────
_check_docker_installed_linux() {
    if ! command -v docker &>/dev/null; then
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

_check_docker_installed_mac() {
    if ! command -v docker &>/dev/null; then
        echo "Docker not found. Please install Docker Desktop for Mac:"
        echo "  https://www.docker.com/products/docker-desktop/"
        exit 1
    fi
<<<<<<< HEAD
    echo "OS user is set to $OS_USER."
    
    if [ -n "${SUDO_UID:-}" ]; then
        SUDO_USER_NAME=$(getent passwd "$SUDO_UID" | cut -d: -f1)
        echo "The UID of the user who invoked sudo is $SUDO_UID."
        echo "The username of the user who invoked sudo is $SUDO_USER_NAME."
        SUDO_USER_HOME_DIR=$(getent passwd "$SUDO_USER_NAME" | cut -d: -f6)
=======
    echo "Docker found at $(command -v docker)"
}

check_docker_installed() {
    if [ "$PLATFORM" = "darwin" ]; then
        _check_docker_installed_mac
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
    else
        _check_docker_installed_linux
    fi
}

<<<<<<< HEAD

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
=======
_ensure_docker_running_linux() {
    for i in {1..5}; do
        if systemctl is-active --quiet docker; then
            echo "Docker is running."
            return
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
        fi
        echo "Docker is not running yet. Starting Docker... (Attempt $i of 5)"
        systemctl restart containerd > /dev/null 2>&1
        systemctl restart docker > /dev/null 2>&1
        sleep 30
    done
<<<<<<< HEAD
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
=======
    echo "Failed to start Docker after 5 attempts."
    echo "Please try: sudo systemctl restart docker"
    echo "Then run this script again."
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
    exit 1
}

_ensure_docker_running_mac() {
    # Fix context/API issues before checking if Docker is up
    _resolve_docker_mac

    if docker info &>/dev/null 2>&1; then
        echo "Docker is running."
        return
    fi

    # Identify which app to launch: prefer whichever is installed
    local docker_app=""
    [ -d "/Applications/OrbStack.app" ]      && docker_app="OrbStack"
    [ -z "$docker_app" ] && [ -d "/Applications/Docker.app" ] && docker_app="Docker"
    if [ -z "$docker_app" ]; then
        echo "No Docker runtime found. Install Docker Desktop or OrbStack:"
        echo "  https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    echo "Docker is not running. Launching $docker_app..."
    open -a "$docker_app" || { echo "Could not launch $docker_app."; exit 1; }

    echo "Waiting for Docker to start (up to 60 seconds)..."
    for i in {1..12}; do
        sleep 5
        _resolve_docker_mac
        if docker info &>/dev/null 2>&1; then
            echo "Docker is running."
            return
        fi
        echo "  Still waiting... ($((i * 5))s)"
    done

    echo "$docker_app did not start within 60 seconds."
    echo "Try starting it manually from Applications and run this script again."
    exit 1
}

ensure_docker_running() {
    if [ "$PLATFORM" = "darwin" ]; then
        _ensure_docker_running_mac
    else
        _ensure_docker_running_linux
    fi
}

_check_docker_compose_linux() {
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

_check_docker_compose_mac() {
    if docker compose version >/dev/null 2>&1; then
        echo "Docker Compose plugin available: $(docker compose version)"
        return
    fi
    echo "Docker Compose plugin not available. Ensure Docker Desktop is up to date."
    exit 1
}

check_docker_compose() {
    if [ "$PLATFORM" = "darwin" ]; then
        _check_docker_compose_mac
    else
        _check_docker_compose_linux
    fi
}

# ─────────────────────────────────────────────────────────────────
# Oracle OS user/group setup — Linux only
# On Mac, Docker Desktop's Linux VM handles uid/gid mapping internally.
# ─────────────────────────────────────────────────────────────────
oracle_os_user_setup() {
    if [ "$PLATFORM" = "darwin" ]; then
        echo "Skipping Oracle OS user setup on macOS (handled inside Docker)."
        return
    fi

    echo "Setting up Oracle user and groups..."
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

    for group in "${!group_ids[@]}"; do
        if ! getent group $group > /dev/null; then
            groupadd -g ${group_ids[$group]} $group
        fi
    done

    if ! id -u oracle > /dev/null 2>&1; then
        useradd -u 54321 -g oinstall -G dba,oper,oinstall,backupdba,dginstall,kmdba,racdba oracle
    fi
}

# ─────────────────────────────────────────────────────────────────
# Oracle Instant Client install — platform-specific
# ─────────────────────────────────────────────────────────────────
_install_oc_linux() {
    local ORACLE_CLIENT_DIR="$SUDO_USER_HOME_DIR/oraclient"
    local BASHRC_FILE="$SUDO_USER_HOME_DIR/.bashrc"

    if ! command -v unzip &>/dev/null; then
        echo "unzip is not installed. Installing..."
        apt update && apt install -y unzip
    fi

    if [ -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
        echo "Oracle Instant Client already installed at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT."
    else
        su - $SUDO_USER_NAME -c "mkdir -p $ORACLE_CLIENT_DIR"
        su - $SUDO_USER_NAME -c "curl -o $ORACLE_CLIENT_DIR/$BASIC_ZIP $BASIC_URL" > /dev/null 2>&1
        su - $SUDO_USER_NAME -c "curl -o $ORACLE_CLIENT_DIR/$SQLPLUS_ZIP $SQLPLUS_URL" > /dev/null 2>&1
        su - $SUDO_USER_NAME -c "unzip -o $ORACLE_CLIENT_DIR/$BASIC_ZIP -d $ORACLE_CLIENT_DIR" > /dev/null 2>&1
        su - $SUDO_USER_NAME -c "unzip -o $ORACLE_CLIENT_DIR/$SQLPLUS_ZIP -d $ORACLE_CLIENT_DIR" > /dev/null 2>&1

        if [ ! -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
            echo "** Error ** Oracle Instant Client not correctly installed in $ORACLE_CLIENT_DIR."
            exit 1
        fi
    fi

    export ORACLE_HOME="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    export LD_LIBRARY_PATH="$ORACLE_HOME"

    # libaio package and symlink differ between Ubuntu versions
    UBUNTU_VER=$(lsb_release -rs | cut -d. -f1)
    if [ "$UBUNTU_VER" -ge 24 ]; then
        apt-get install -y libaio1t64
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1t64"
    else
        apt-get install -y libaio1
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1.0.1"
    fi
    LIBAIO_LINK="/usr/lib/x86_64-linux-gnu/libaio.so.1"
    if [ ! -e "$LIBAIO_LINK" ] || [ "$(readlink $LIBAIO_LINK)" != "$LIBAIO_TARGET" ]; then
        echo "Creating/fixing libaio.so.1 symlink -> $LIBAIO_TARGET"
        ln -sf "$LIBAIO_TARGET" "$LIBAIO_LINK"
    fi

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

# Mount a DMG, run Oracle's install_ic.sh from the volume, then unmount.
# install_ic.sh installs files into ~/Downloads/instantclient_XX_XX by default.
_install_dmg_mac() {
    local dmg="$1"
    local label
    label=$(basename "$dmg" .dmg)

    echo "Mounting $label..."
    local vol
    vol=$(hdiutil attach -nobrowse "$dmg" 2>/dev/null \
          | awk '/\/Volumes\// {print $NF; exit}')
    if [ -z "$vol" ] || [ ! -d "$vol" ]; then
        echo "** Error ** Failed to mount $dmg"
        exit 1
    fi
    echo "Mounted at $vol — running install_ic.sh..."
    (cd "$vol" && sh ./install_ic.sh) 2>&1
    local rc=$?
    hdiutil detach "$vol" 2>/dev/null || true
    if [ $rc -ne 0 ]; then
        echo "** Error ** install_ic.sh failed for $label (exit $rc)"
        exit 1
    fi
}

_install_oc_mac() {
    local ORACLE_CLIENT_DIR="$SUDO_USER_HOME_DIR/oraclient"
    local SHELL_RC="$SUDO_USER_HOME_DIR/.zshrc"
    # Oracle's install_ic.sh puts files here by default
    local DEFAULT_IC_DIR="$SUDO_USER_HOME_DIR/Downloads/$INSTANT_CLIENT"

    if [ -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
        echo "Oracle Instant Client already installed at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT."
    else
        local basic_dmg="$ORACLE_CLIENT_DIR/$BASIC_ZIP"
        local sqlplus_dmg="$ORACLE_CLIENT_DIR/$SQLPLUS_ZIP"

        mkdir -p "$ORACLE_CLIENT_DIR"

        echo "Downloading Oracle Instant Client Basic DMG for macOS ($ARCH)..."
        curl -L -o "$basic_dmg" "$BASIC_URL"
        echo "Downloading Oracle Instant Client SQL*Plus DMG for macOS ($ARCH)..."
        curl -L -o "$sqlplus_dmg" "$SQLPLUS_URL"

        # Clear any leftover default install dir from a prior attempt
        [ -d "$DEFAULT_IC_DIR" ] && rm -rf "$DEFAULT_IC_DIR"

        # install_ic.sh creates ~/Downloads/instantclient_XX_XX and copies files there
        _install_dmg_mac "$basic_dmg"
        _install_dmg_mac "$sqlplus_dmg"

        if [ ! -d "$DEFAULT_IC_DIR" ]; then
            echo "** Error ** install_ic.sh did not create $DEFAULT_IC_DIR"
            exit 1
        fi

        # Move from the default ~/Downloads location to our oraclient dir
        mkdir -p "$ORACLE_CLIENT_DIR"
        mv "$DEFAULT_IC_DIR" "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"

        if [ ! -f "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus" ]; then
            echo "** Error ** sqlplus not found after install. Check $ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
            exit 1
        fi
        echo "Oracle Instant Client installed at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    fi

    export ORACLE_HOME="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    export DYLD_LIBRARY_PATH="$ORACLE_HOME"

    if ! grep -q "export ORACLE_HOME=$ORACLE_HOME" "$SHELL_RC"; then
        echo "export ORACLE_HOME=$ORACLE_HOME" >> "$SHELL_RC"
    fi
    if ! grep -q "export DYLD_LIBRARY_PATH=$ORACLE_HOME" "$SHELL_RC"; then
        echo "export DYLD_LIBRARY_PATH=$ORACLE_HOME" >> "$SHELL_RC"
    fi
    if ! grep -q "export PATH=$ORACLE_HOME:\$PATH" "$SHELL_RC"; then
        echo "export PATH=$ORACLE_HOME:\$PATH" >> "$SHELL_RC"
    fi
}

install_oracle_instant_client() {
    if [ "$PLATFORM" = "darwin" ]; then
        _install_oc_mac
    else
        _install_oc_linux
    fi
}

# ─────────────────────────────────────────────────────────────────
# APEX preparation and ORDS config dir
# ─────────────────────────────────────────────────────────────────
prepare_apex() {
    local EFFECTIVE_APEX_DIR="${APEX_DIR:-$SUDO_USER_HOME_DIR/apex}"
    local APEX_ZIP="$SUDO_USER_HOME_DIR/apex-latest.zip"
    local APEX_PARENT
    APEX_PARENT=$(dirname "$EFFECTIVE_APEX_DIR")

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
        [ "$PLATFORM" = "linux" ] && chown "$SUDO_USER_NAME" "$APEX_ZIP" 2>/dev/null || true
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
    [ "$PLATFORM" = "linux" ] && chown -R "$SUDO_USER_NAME" "$EFFECTIVE_APEX_DIR" 2>/dev/null || true
    echo "APEX prepared at $EFFECTIVE_APEX_DIR."
}

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

<<<<<<< HEAD
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
=======
# ─────────────────────────────────────────────────────────────────
# Volume ownership — Linux only
# Docker Desktop on Mac manages uid/gid mapping inside its VM.
# ─────────────────────────────────────────────────────────────────
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
change_volume_ownership() {
    if [ "$PLATFORM" = "darwin" ]; then
        return
    fi
    VOL_PATH=$(docker volume inspect "$VOL_NAME" --format '{{ .Mountpoint }}')
    if [ -z "$VOL_PATH" ]; then
        echo "Failed to determine the volume path for $VOL_NAME. Exiting."
        exit 1
    fi
    echo "Changing ownership of volume path $VOL_PATH to user oracle and group oinstall."
    sudo chown -R oracle:oinstall "$VOL_PATH"
}

create_docker_volume() {
    echo "Creating Docker volume $VOL_NAME..."
    if docker volume inspect "$VOL_NAME" >/dev/null 2>&1; then
        echo "Warning: Volume '$VOL_NAME' already exists."
<<<<<<< HEAD
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
=======
        read -p "Do you want to use the existing volume? (y/n): " choice
        case "$choice" in
            y|Y ) echo "Using existing volume '$VOL_NAME'." ;;
            n|N ) echo "Exiting. Remove the volume with: docker volume rm $VOL_NAME"; exit 1 ;;
            *   ) echo "Invalid choice. Exiting."; exit 1 ;;
        esac
    else
        docker volume create $VOL_NAME
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
        change_volume_ownership
    fi
}

# ─────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────
preflight_check() {
    local warnings=0
    echo "--- Pre-flight checks ---"

    if ! curl -s --max-time 8 -o /dev/null "https://download.oracle.com" 2>/dev/null; then
        echo "WARNING: Cannot reach download.oracle.com — Instant Client download may fail."
        warnings=$((warnings + 1))
    fi

    if ! curl -s --max-time 8 -o /dev/null "https://download.oracle.com/otn_software/apex/" 2>/dev/null; then
        echo "WARNING: Cannot reach Oracle APEX download URL — APEX download may fail."
        warnings=$((warnings + 1))
    fi

    if [ -n "$ORACLE_REGISTRY_USER" ] && [ -n "$ORACLE_REGISTRY_PASSWORD" ]; then
        echo "Oracle Container Registry credentials configured — login will be attempted."
    fi

    local home_dir="${SUDO_USER_HOME_DIR:-$HOME}"
    local avail_kb
    avail_kb=$(avail_kb_for_dir "$home_dir")
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 2097152 ]; then  # 2 GB
        echo "WARNING: Less than 2 GB free in $home_dir — downloads may fail."
        warnings=$((warnings + 1))
    fi

    if [ "$warnings" -gt 0 ]; then
        echo "--- $warnings warning(s) noted above. Continuing... ---"
    else
        echo "--- Pre-flight checks passed ---"
    fi
}

<<<<<<< HEAD
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
=======
# ─────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: $0 [-c] [-h]"
    echo "Options:"
    echo "  -c  Cleanup Docker and related configurations"
    echo "  -h  Display this help"
    exit 1
}

read_config() {
    CONFIG_FILE="$RUN_DIR/config.ini"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file config.ini not found in $RUN_DIR. Exiting."
        exit 1
    fi

    HOSTNAME=$(ini_val HOSTNAME)
    DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD)
    ORACLE_REGISTRY_USER=$(ini_val ORACLE_REGISTRY_USER)
    ORACLE_REGISTRY_PASSWORD=$(ini_val ORACLE_REGISTRY_PASSWORD)
    DOCKER_IMAGE=$(ini_val DOCKER_IMAGE)
    APEX_DIR=$(ini_val APEX_DIR)

    if [ "$PLATFORM" = "darwin" ]; then
        # Mac: prefer *_MAC keys, fall back to generic keys if Mac-specific ones are absent
        BASIC_ZIP=$(ini_val BASIC_ZIP_MAC)
        SQLPLUS_ZIP=$(ini_val SQLPLUS_ZIP_MAC)
        BASIC_URL=$(ini_val BASIC_URL_MAC)
        SQLPLUS_URL=$(ini_val SQLPLUS_URL_MAC)
        INSTANT_CLIENT=$(ini_val INSTANT_CLIENT_MAC)
        # Fall back to generic keys if Mac-specific entries are missing
        [ -z "$BASIC_ZIP" ]      && BASIC_ZIP=$(ini_val BASIC_ZIP)
        [ -z "$SQLPLUS_ZIP" ]    && SQLPLUS_ZIP=$(ini_val SQLPLUS_ZIP)
        [ -z "$BASIC_URL" ]      && BASIC_URL=$(ini_val BASIC_URL)
        [ -z "$SQLPLUS_URL" ]    && SQLPLUS_URL=$(ini_val SQLPLUS_URL)
        [ -z "$INSTANT_CLIENT" ] && INSTANT_CLIENT=$(ini_val INSTANT_CLIENT)
    else
        BASIC_ZIP=$(ini_val BASIC_ZIP)
        SQLPLUS_ZIP=$(ini_val SQLPLUS_ZIP)
        BASIC_URL=$(ini_val BASIC_URL)
        SQLPLUS_URL=$(ini_val SQLPLUS_URL)
        INSTANT_CLIENT=$(ini_val INSTANT_CLIENT)
    fi

    local missing=""
    [ -z "$BASIC_ZIP" ]      && missing="$missing BASIC_ZIP"
    [ -z "$SQLPLUS_ZIP" ]    && missing="$missing SQLPLUS_ZIP"
    [ -z "$BASIC_URL" ]      && missing="$missing BASIC_URL"
    [ -z "$SQLPLUS_URL" ]    && missing="$missing SQLPLUS_URL"
    [ -z "$INSTANT_CLIENT" ] && missing="$missing INSTANT_CLIENT"
    [ -z "$HOSTNAME" ]       && missing="$missing HOSTNAME"
    [ -z "$DEFAULT_PASSWORD" ] && missing="$missing DEFAULT_PASSWORD"
    [ -z "$DOCKER_IMAGE" ]   && missing="$missing DOCKER_IMAGE"
    if [ -n "$missing" ]; then
        echo "Missing required config.ini values:$missing. Exiting."
        exit 1
    fi
}

####### main #######
PLATFORM=""
ARCH=""
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
SUDO_USER_NAME=""
SUDO_USER_HOME_DIR=""
TNS_ADMIN=""
ORACLE_HOME=""
ORACLE_CLIENT_DIR=""
INSTANT_CLIENT=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

<<<<<<< HEAD
############# don't change these ############
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in

# Resolve the invoking user early (needed by cleanup)
set_sudo_user

# Parse arguments before read_config so cleanup doesn't need a valid config
=======
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

detect_platform
[ "$PLATFORM" = "darwin" ] && _resolve_docker_mac
read_config
set_sudo_user

>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
while getopts "hc" opt; do
    case ${opt} in
        h ) usage ;;
        c ) cleanup ;;
        \? ) usage ;;
    esac
done

<<<<<<< HEAD
# Read configuration (only reached if not cleanup/help)
read_config

# Call the functions to perform the checks
=======
>>>>>>> 94f31f6 (now deploys DB container and ords/apex on m4 mac)
check_root_user
check_os
preflight_check
check_and_install_packages "unzip" "curl" "git"
check_and_add_hostname
echo "User: $SUDO_USER_NAME"
check_docker_installed
ensure_docker_running
oracle_os_user_setup
install_oracle_instant_client
oracle_registry_login
check_docker_compose
prepare_apex
create_ords_config_dir
install_python_deps

# Fix ownership of files created as root during this or prior sudo runs (Linux only).
if [ "$PLATFORM" = "linux" ] && [ -n "$SUDO_USER_NAME" ]; then
    for f in "$RUN_DIR/.env" "$RUN_DIR/ords_config" "$RUN_DIR/sql-scripts/create-users.sql"; do
        [ -e "$f" ] && chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$f" 2>/dev/null || true
    done
fi

echo
echo "OS and Docker Setup for ADB 26ai completed"
echo "Next step: run ./run-adb-26ai.sh to start the database and ORDS/APEX"
