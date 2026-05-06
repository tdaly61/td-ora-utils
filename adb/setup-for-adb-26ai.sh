#!/usr/bin/env bash
set -euo pipefail

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
        umount /var/lib/docker > /dev/null 2>&1 || true
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
        echo "Docker resources cleaned. Remove Colima VM with: colima delete"
    fi
    exit 0
}

# ─────────────────────────────────────────────────────────────────
# OS checks and user resolution
# ─────────────────────────────────────────────────────────────────
check_root_user() {
    if [ "$PLATFORM" = "darwin" ]; then
        return   # macOS: run as normal user (no sudo needed)
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
        SUDO_USER_HOME_DIR=$(eval echo ~"$SUDO_USER_NAME")
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
# Docker — Linux-specific install and start functions.
# macOS equivalents live in mac_helpers.sh (sourced below on Darwin).
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

    if [ -n "$SUDO_USER_NAME" ] && ! id -nG "$SUDO_USER_NAME" | grep -qw docker; then
        echo "Adding $SUDO_USER_NAME to the docker group..."
        usermod -aG docker "$SUDO_USER_NAME"
        echo "Done. Docker group will be active in new login sessions."
        echo "run-adb-26ai.sh will apply it automatically in the current session."
    else
        echo "User $SUDO_USER_NAME is already in the docker group."
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

# Platform-dispatch wrappers — macOS implementations are in mac_helpers.sh
install_docker() {
    [ "$PLATFORM" = "darwin" ] && install_docker_mac && return
    _check_docker_installed_linux   # Linux: install doubles as 'ensure installed'
}

check_docker_installed() {
    [ "$PLATFORM" = "darwin" ] && check_docker_installed_mac && return
    _check_docker_installed_linux
}

ensure_docker_running() {
    [ "$PLATFORM" = "darwin" ] && ensure_docker_running_mac && return
    _ensure_docker_running_linux
}

# ─────────────────────────────────────────────────────────────────
# Oracle OS user/group setup — Linux only
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
        if ! getent group "$group" > /dev/null; then
            groupadd -g "${group_ids[$group]}" "$group"
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
        su - "$SUDO_USER_NAME" -c "mkdir -p $ORACLE_CLIENT_DIR"
        su - "$SUDO_USER_NAME" -c "curl -o $ORACLE_CLIENT_DIR/$BASIC_ZIP $BASIC_URL" > /dev/null 2>&1
        su - "$SUDO_USER_NAME" -c "curl -o $ORACLE_CLIENT_DIR/$SQLPLUS_ZIP $SQLPLUS_URL" > /dev/null 2>&1
        su - "$SUDO_USER_NAME" -c "unzip -o $ORACLE_CLIENT_DIR/$BASIC_ZIP -d $ORACLE_CLIENT_DIR" > /dev/null 2>&1
        su - "$SUDO_USER_NAME" -c "unzip -o $ORACLE_CLIENT_DIR/$SQLPLUS_ZIP -d $ORACLE_CLIENT_DIR" > /dev/null 2>&1

        if [ ! -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
            echo "** Error ** Oracle Instant Client not correctly installed in $ORACLE_CLIENT_DIR."
            exit 1
        fi
    fi

    export ORACLE_HOME="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    export LD_LIBRARY_PATH="$ORACLE_HOME"

    UBUNTU_VER=$(lsb_release -rs | cut -d. -f1)
    if [ "$UBUNTU_VER" -ge 24 ]; then
        apt-get install -y libaio1t64
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1t64"
    else
        apt-get install -y libaio1
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1.0.1"
    fi
    LIBAIO_LINK="/usr/lib/x86_64-linux-gnu/libaio.so.1"
    if [ ! -e "$LIBAIO_LINK" ] || [ "$(readlink "$LIBAIO_LINK")" != "$LIBAIO_TARGET" ]; then
        echo "Creating/fixing libaio.so.1 symlink -> $LIBAIO_TARGET"
        ln -sf "$LIBAIO_TARGET" "$LIBAIO_LINK"
    fi

    local tns_admin_path="$SUDO_USER_HOME_DIR/auth/tls_wallet"
    if ! grep -q "export TNS_ADMIN=" "$BASHRC_FILE"; then
        echo "export TNS_ADMIN=$tns_admin_path" >> "$BASHRC_FILE"
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

        [ -d "$DEFAULT_IC_DIR" ] && rm -rf "$DEFAULT_IC_DIR"
        _install_dmg_mac "$basic_dmg"
        _install_dmg_mac "$sqlplus_dmg"

        if [ ! -d "$DEFAULT_IC_DIR" ]; then
            echo "** Error ** install_ic.sh did not create $DEFAULT_IC_DIR"
            exit 1
        fi

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
# Oracle Container Registry login — optional (free-tier images accessible without login)
# ─────────────────────────────────────────────────────────────────
oracle_registry_login() {
    if [ -z "$ORACLE_REGISTRY_USER" ] || [ -z "$ORACLE_REGISTRY_PASSWORD" ]; then
        echo "Oracle Container Registry credentials not set — skipping login."
        return
    fi
    echo "Logging in to Oracle Container Registry as $ORACLE_REGISTRY_USER..."
    echo "$ORACLE_REGISTRY_PASSWORD" | docker login container-registry.oracle.com \
        -u "$ORACLE_REGISTRY_USER" --password-stdin
    if [ $? -ne 0 ]; then
        echo "Docker login failed. Check credentials at https://container-registry.oracle.com"
        exit 1
    fi
    echo "Oracle Container Registry login successful."
}

# ─────────────────────────────────────────────────────────────────
# Ollama (optional — commented out in main by default)
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
    echo "Usage: $0 [-n] [-c] [-h]"
    echo "Options:"
    echo "  -n  Dry-run: print what would be done without making any changes"
    echo "  -c  Cleanup Docker and related configurations"
    echo "  -h  Display this help"
    exit 1
}

# Print a summary of what setup would do on this machine, then exit.
# Call after read_config and set_sudo_user so all variables are populated.
show_dry_run_plan() {
    local home_dir="${SUDO_USER_HOME_DIR:-$HOME}"
    local client_dir="$home_dir/oraclient/$INSTANT_CLIENT"

    echo ""
    echo "=== DRY-RUN plan for setup-for-adb-26ai.sh ==="
    echo ""
    echo "  Platform  : $PLATFORM / $ARCH"
    echo "  Config    : $CONFIG_FILE"
    echo "  Image     : $DOCKER_IMAGE"
    echo "  Container : $(ini_val CONTAINER_NAME 2>/dev/null)"
    echo "  User home : $home_dir"
    echo ""

    # Step 1: /etc/hosts
    if grep -q "${HOSTNAME}" /etc/hosts 2>/dev/null; then
        echo "1. /etc/hosts — '$HOSTNAME' already present, no change needed"
    else
        echo "1. /etc/hosts — add '$HOSTNAME' to 127.0.0.1 line"
    fi

    # Step 2: Docker / Colima
    echo ""
    if [ "$PLATFORM" = "darwin" ]; then
        echo "2. Docker runtime: Colima"
        if command -v colima &>/dev/null && command -v docker &>/dev/null; then
            echo "   colima + docker CLI already installed — skip brew install"
        else
            echo "   brew install colima docker"
        fi
        if colima status 2>/dev/null | grep -q "Running"; then
            echo "   Colima already running — reuse existing VM"
        elif colima list 2>/dev/null | grep -q "default"; then
            echo "   Colima VM exists but stopped — colima start (existing VM, sizing flags ignored)"
        else
            local rosetta_flag=""
            [ "$COLIMA_VM_TYPE" = "vz" ] && [ "$COLIMA_VZ_ROSETTA" = "true" ] && rosetta_flag=" --vz-rosetta"
            echo "   No Colima VM detected — would create:"
            echo "   colima start --arch $COLIMA_ARCH --memory $COLIMA_MEMORY --disk $COLIMA_DISK"
            echo "                --runtime docker --vm-type $COLIMA_VM_TYPE${rosetta_flag}"
        fi
    else
        echo "2. Docker (Linux)"
        if command -v docker &>/dev/null; then
            echo "   docker already installed at $(command -v docker) — skip apt install"
        else
            echo "   apt install -y docker.io"
            echo "   systemctl enable docker && systemctl restart docker"
        fi
        if [ -n "$SUDO_USER_NAME" ] && id -nG "$SUDO_USER_NAME" 2>/dev/null | grep -qw docker; then
            echo "   $SUDO_USER_NAME already in docker group — skip usermod"
        else
            echo "   usermod -aG docker $SUDO_USER_NAME"
        fi
        echo ""
        echo "3. Oracle OS groups/user (linux)"
        if id -u oracle &>/dev/null 2>&1; then
            echo "   oracle user already exists — skip groupadd/useradd"
        else
            echo "   groupadd: oinstall dba oper backupdba dginstall kmdba racdba"
            echo "   useradd -u 54321 oracle"
        fi
    fi

    # Step 3/4: Oracle Instant Client
    echo ""
    local step_ic=3
    [ "$PLATFORM" = "linux" ] && step_ic=4
    echo "$step_ic. Oracle Instant Client"
    if [ -d "$client_dir" ]; then
        echo "   Already installed at $client_dir — skip download/install"
    else
        echo "   Download: $BASIC_URL"
        echo "   Download: $SQLPLUS_URL"
        if [ "$PLATFORM" = "darwin" ]; then
            echo "   Mount DMG → install_ic.sh → move to $client_dir"
        else
            echo "   unzip to $home_dir/oraclient/$INSTANT_CLIENT"
            echo "   apt install libaio1(t64) + symlink libaio.so.1"
        fi
        echo "   Append ORACLE_HOME / LD/DYLD_LIBRARY_PATH / PATH to shell RC"
    fi

    # Step N: Registry login
    echo ""
    local step_reg=$((step_ic + 1))
    if [[ "${DOCKER_IMAGE:-}" == ghcr.io/* ]]; then
        echo "$step_reg. Docker registry login — not required for GHCR image (ghcr.io)"
    elif [ -n "${ORACLE_REGISTRY_USER:-}" ] && [ -n "${ORACLE_REGISTRY_PASSWORD:-}" ]; then
        echo "$step_reg. docker login container-registry.oracle.com -u $ORACLE_REGISTRY_USER"
    else
        echo "$step_reg. Docker registry login — skip (no credentials in config.ini)"
    fi

    echo ""
    echo "=== No changes made (dry-run). Run without -n to execute. ==="
    exit 0
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
    CONTAINER_RUNTIME=$(ini_val CONTAINER_RUNTIME)
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
    COLIMA_ARCH=$(ini_val COLIMA_ARCH);           COLIMA_ARCH="${COLIMA_ARCH:-x86_64}"
    COLIMA_VM_TYPE=$(ini_val COLIMA_VM_TYPE);     COLIMA_VM_TYPE="${COLIMA_VM_TYPE:-vz}"
    COLIMA_VZ_ROSETTA=$(ini_val COLIMA_VZ_ROSETTA); COLIMA_VZ_ROSETTA="${COLIMA_VZ_ROSETTA:-true}"
    COLIMA_MEMORY=$(ini_val COLIMA_MEMORY);       COLIMA_MEMORY="${COLIMA_MEMORY:-8}"
    COLIMA_DISK=$(ini_val COLIMA_DISK);           COLIMA_DISK="${COLIMA_DISK:-100}"

    if [ "$PLATFORM" = "darwin" ]; then
        BASIC_ZIP=$(ini_val BASIC_ZIP_MAC)
        SQLPLUS_ZIP=$(ini_val SQLPLUS_ZIP_MAC)
        BASIC_URL=$(ini_val BASIC_URL_MAC)
        SQLPLUS_URL=$(ini_val SQLPLUS_URL_MAC)
        INSTANT_CLIENT=$(ini_val INSTANT_CLIENT_MAC)
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
    [ -z "$BASIC_ZIP" ]        && missing="$missing BASIC_ZIP"
    [ -z "$SQLPLUS_ZIP" ]      && missing="$missing SQLPLUS_ZIP"
    [ -z "$BASIC_URL" ]        && missing="$missing BASIC_URL"
    [ -z "$SQLPLUS_URL" ]      && missing="$missing SQLPLUS_URL"
    [ -z "$INSTANT_CLIENT" ]   && missing="$missing INSTANT_CLIENT"
    [ -z "$HOSTNAME" ]         && missing="$missing HOSTNAME"
    [ -z "$DEFAULT_PASSWORD" ] && missing="$missing DEFAULT_PASSWORD"
    [ -z "$DOCKER_IMAGE" ]     && missing="$missing DOCKER_IMAGE"
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
WALLET_DIR=""
DRY_RUN=false
COLIMA_ARCH=""
COLIMA_VM_TYPE=""
COLIMA_VZ_ROSETTA=""
COLIMA_MEMORY=""
COLIMA_DISK=""

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

detect_platform

# Source macOS helpers before read_config so CONTAINER_RUNTIME is available to them.
if [ "$PLATFORM" = "darwin" ]; then
    # shellcheck source=mac_helpers.sh
    source "$RUN_DIR/mac_helpers.sh"
fi

read_config
set_sudo_user

while getopts "hcn" opt; do
    case ${opt} in
        h ) usage ;;
        c ) cleanup ;;
        n ) DRY_RUN=true ;;
        \? ) usage ;;
    esac
done

if [ "$DRY_RUN" = "true" ]; then
    show_dry_run_plan
fi

check_root_user
check_os
preflight_check
check_and_install_packages "unzip" "curl" "git"
check_and_add_hostname
echo "User: $SUDO_USER_NAME"

# Docker lifecycle:
#  1. install_docker  — brew install colima docker  (macOS) / apt install docker.io  (Linux)
#  2. check_docker_installed  — verify binaries present
#  3. ensure_docker_running   — start runtime (creates Colima VM if needed)
install_docker
check_docker_installed
ensure_docker_running

oracle_os_user_setup
install_oracle_instant_client
oracle_registry_login
# install_ollama
# launch_ollama_model

echo
echo "Setup for Oracle ADB-Free 26ai completed."
echo "Next step: run ./run-adb-26ai.sh to start the database"
