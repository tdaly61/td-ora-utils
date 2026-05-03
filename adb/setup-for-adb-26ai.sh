#!/usr/bin/env bash

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
        for ctx in rancher-desktop desktop-linux default orbstack; do
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
    local runtime="${CONTAINER_RUNTIME:-auto}"

    # Rancher Desktop: docker lives at ~/.rd/bin/docker (may not be on PATH under sudo)
    if [ "$runtime" = "rancher" ]; then
        # Docker Desktop must not be installed — it hijacks ~/.docker/cli-plugins/ and
        # breaks docker compose / buildx even when its daemon is not running.
        if [ -d "/Applications/Docker.app" ]; then
            echo ""
            echo "** Error: Docker Desktop is installed but CONTAINER_RUNTIME=rancher is set."
            echo "   Docker Desktop hijacks ~/.docker/cli-plugins/ and breaks Rancher Desktop's"
            echo "   docker compose and buildx plugins even when Docker Desktop is not running."
            echo ""
            echo "   Remove Docker Desktop before running this script again:"
            echo ""
            echo "   Option 1 — built-in uninstaller then remove the app bundle (DMG install):"
            echo "     sudo /Applications/Docker.app/Contents/MacOS/uninstall"
            echo "     rm -rf /Applications/Docker.app"
            echo ""
            echo "   Option 2 — Homebrew (if installed via brew):"
            echo "     brew uninstall --cask docker"
            echo ""
            echo "   Rancher Desktop provides docker, docker-compose, buildx, kubectl and helm"
            echo "   — Docker Desktop is not needed."
            echo ""
            exit 1
        fi

        local rd_docker="$HOME/.rd/bin/docker"
        if [ -x "$rd_docker" ]; then
            [[ ":$PATH:" != *":$HOME/.rd/bin:"* ]] && export PATH="$HOME/.rd/bin:$PATH"
            echo "Rancher Desktop docker found at $rd_docker"
            return
        fi
        if [ -d "/Applications/Rancher Desktop.app" ]; then
            # App installed but not yet started — docker binary appears after first start
            return
        fi
        echo "Rancher Desktop not found. Install from https://rancherdesktop.io/"
        echo "Or change CONTAINER_RUNTIME to docker_desktop or auto in config.ini."
        exit 1
    fi

    # For all other runtimes: add ~/.rd/bin to PATH if Rancher Desktop is installed
    [ -d "/Applications/Rancher Desktop.app" ] && \
        [[ ":$PATH:" != *":$HOME/.rd/bin:"* ]] && \
        export PATH="$HOME/.rd/bin:$PATH"

    if command -v docker &>/dev/null; then
        echo "Docker found at $(command -v docker)"
        return
    fi

    echo "Docker not found. Install one of:"
    echo "  Rancher Desktop (set CONTAINER_RUNTIME=rancher): https://rancherdesktop.io/"
    echo "  Docker Desktop:  https://www.docker.com/products/docker-desktop/"
    echo "  OrbStack:        https://orbstack.dev/"
    exit 1
}

check_docker_installed() {
    if [ "$PLATFORM" = "darwin" ]; then
        _check_docker_installed_mac
    else
        _check_docker_installed_linux
    fi
}

_ensure_docker_running_linux() {
    for i in {1..5}; do
        if systemctl is-active --quiet docker; then
            echo "Docker is running."
            return
        fi
        echo "Docker is not running yet. Starting Docker... (Attempt $i of 5)"
        systemctl restart containerd > /dev/null 2>&1
        systemctl restart docker > /dev/null 2>&1
        sleep 30
    done
    echo "Failed to start Docker after 5 attempts."
    echo "Please try: sudo systemctl restart docker"
    echo "Then run this script again."
    exit 1
}

_ensure_docker_running_mac() {
    # Ensure ~/.rd/bin is on PATH whenever Rancher Desktop is installed
    [ -d "/Applications/Rancher Desktop.app" ] && \
        [[ ":$PATH:" != *":$HOME/.rd/bin:"* ]] && \
        export PATH="$HOME/.rd/bin:$PATH"

    # When rancher runtime is requested, force the rancher-desktop context before
    # checking docker — otherwise a running Docker Desktop satisfies docker info
    # and the script never configures Rancher Desktop.
    if [ "${CONTAINER_RUNTIME:-auto}" = "rancher" ]; then
        docker context use rancher-desktop &>/dev/null 2>&1 || true
    fi

    _resolve_docker_mac
    if docker info &>/dev/null 2>&1; then
        echo "Docker is running."
        return
    fi

    local runtime="${CONTAINER_RUNTIME:-auto}"

    # Build try-order: preferred runtime first, then fall back to others that are installed
    local -a try_order=()
    case "$runtime" in
        rancher)        try_order=(rancher docker_desktop orbstack) ;;
        docker_desktop) try_order=(docker_desktop orbstack rancher) ;;
        orbstack)       try_order=(orbstack docker_desktop rancher) ;;
        *)              try_order=(orbstack docker_desktop rancher) ;;  # auto
    esac

    for rt in "${try_order[@]}"; do
        case "$rt" in
            rancher)
                [ -d "/Applications/Rancher Desktop.app" ] || continue
                local rdctl=""
                for candidate in \
                    "$HOME/.rd/bin/rdctl" \
                    "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin/rdctl" \
                    "/usr/local/bin/rdctl" "/opt/homebrew/bin/rdctl"; do
                    [ -x "$candidate" ] && rdctl="$candidate" && break
                done
                [ -z "$rdctl" ] && continue
                echo "Starting Rancher Desktop..."
                "$rdctl" start --application.start-in-background
                echo "Waiting for Rancher Desktop to become ready (up to 120 seconds)..."
                for i in {1..24}; do
                    sleep 5
                    [[ ":$PATH:" != *":$HOME/.rd/bin:"* ]] && export PATH="$HOME/.rd/bin:$PATH"
                    _resolve_docker_mac
                    if docker info &>/dev/null 2>&1; then echo "Docker is running."; return; fi
                    echo "  Still waiting... ($((i * 5))s)"
                done
                echo "  Rancher Desktop did not become ready within 120 seconds."
                ;;
            docker_desktop)
                [ -d "/Applications/Docker.app" ] || continue
                echo "Starting Docker Desktop..."
                open -a "Docker" || continue
                echo "Waiting for Docker Desktop to start (up to 60 seconds)..."
                for i in {1..12}; do
                    sleep 5
                    _resolve_docker_mac
                    if docker info &>/dev/null 2>&1; then echo "Docker is running."; return; fi
                    echo "  Still waiting... ($((i * 5))s)"
                done
                echo "  Docker Desktop did not start within 60 seconds."
                ;;
            orbstack)
                [ -d "/Applications/OrbStack.app" ] || continue
                echo "Starting OrbStack..."
                open -a "OrbStack" || continue
                echo "Waiting for OrbStack to start (up to 60 seconds)..."
                for i in {1..12}; do
                    sleep 5
                    _resolve_docker_mac
                    if docker info &>/dev/null 2>&1; then echo "Docker is running."; return; fi
                    echo "  Still waiting... ($((i * 5))s)"
                done
                echo "  OrbStack did not start within 60 seconds."
                ;;
        esac
    done

    echo "No Docker runtime could be started. Install one of:"
    echo "  Rancher Desktop: https://rancherdesktop.io/"
    echo "  Docker Desktop:  https://www.docker.com/products/docker-desktop/"
    echo "  OrbStack:        https://orbstack.dev/"
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

# ─────────────────────────────────────────────────────────────────
# Volume ownership — Linux only
# Docker Desktop on Mac manages uid/gid mapping inside its VM.
# ─────────────────────────────────────────────────────────────────
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
        read -p "Do you want to use the existing volume? (y/n): " choice
        case "$choice" in
            y|Y ) echo "Using existing volume '$VOL_NAME'." ;;
            n|N ) echo "Exiting. Remove the volume with: docker volume rm $VOL_NAME"; exit 1 ;;
            *   ) echo "Invalid choice. Exiting."; exit 1 ;;
        esac
    else
        docker volume create $VOL_NAME
        change_volume_ownership
    fi
}

# ─────────────────────────────────────────────────────────────────
# Ollama installation and model launch
# ─────────────────────────────────────────────────────────────────
_install_ollama_linux() {
    if command -v ollama &>/dev/null; then
        echo "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
        return
    fi
    echo "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    sleep 3
    if ! command -v ollama &>/dev/null; then
        echo "** Error ** Ollama installation failed."
        exit 1
    fi
    echo "Ollama installed: $(ollama --version 2>/dev/null)"
}

_install_ollama_mac() {
    if command -v ollama &>/dev/null; then
        echo "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
        return
    fi
    if command -v brew &>/dev/null; then
        echo "Installing Ollama via Homebrew..."
        brew install ollama
    else
        echo "Ollama not found. Install it from https://ollama.com/download or: brew install ollama"
        exit 1
    fi
}

install_ollama() {
    if [ "$PLATFORM" = "darwin" ]; then
        _install_ollama_mac
    else
        _install_ollama_linux
    fi
}

launch_ollama_model() {
    local model="${OLLAMA_MODEL:-qwen3-coder-cc:latest}"

    if [ "$PLATFORM" = "linux" ]; then
        # Ensure the systemd service is running (ollama install.sh creates it)
        if ! systemctl is-active --quiet ollama 2>/dev/null; then
            echo "Starting ollama service..."
            systemctl enable ollama 2>/dev/null || true
            systemctl start ollama 2>/dev/null || true
            sleep 3
        fi
        local run_as="${SUDO_USER_NAME:-$(id -un)}"
        echo "Launching ollama model $model as $run_as..."
        su - "$run_as" -c "OLLAMA_KEEP_ALIVE=1h ollama launch claude --model $model"
    else
        # macOS: start ollama serve in the background if not already running
        if ! pgrep -x ollama &>/dev/null; then
            echo "Starting ollama server in background..."
            OLLAMA_KEEP_ALIVE=1h ollama serve &>/dev/null &
            sleep 3
        fi
        echo "Launching ollama model $model..."
        OLLAMA_KEEP_ALIVE=1h ollama launch claude --model "$model"
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
    OLLAMA_MODEL=$(ini_val OLLAMA_MODEL)   # optional; defaults to qwen3-coder-cc:latest
    CONTAINER_RUNTIME=$(ini_val CONTAINER_RUNTIME)
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"

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
SUDO_USER_NAME=""
SUDO_USER_HOME_DIR=""
TNS_ADMIN=""
ORACLE_HOME=""
ORACLE_CLIENT_DIR=""
INSTANT_CLIENT=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

detect_platform
[ "$PLATFORM" = "darwin" ] && _resolve_docker_mac
read_config
set_sudo_user

while getopts "hc" opt; do
    case ${opt} in
        h ) usage ;;
        c ) cleanup ;;
        \? ) usage ;;
    esac
done

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
# install_ollama
# launch_ollama_model

# Fix ownership of files created as root during this or prior sudo runs (Linux only).
if [ "$PLATFORM" = "linux" ] && [ -n "$SUDO_USER_NAME" ]; then
    for f in "$RUN_DIR/.env" "$RUN_DIR/ords_config" "$RUN_DIR/sql-scripts/create-users.sql"; do
        [ -e "$f" ] && chown -R "$SUDO_USER_NAME:$SUDO_USER_NAME" "$f" 2>/dev/null || true
    done
fi

echo
echo "OS and Docker Setup for ADB 26ai completed"
echo "Next step: run ./run-adb-26ai.sh to start the database and ORDS/APEX"
