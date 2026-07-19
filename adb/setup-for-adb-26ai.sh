#!/usr/bin/env bash
set -euo pipefail

# Platform detection (detect_platform) lives in common.sh — sourced further down,
# right after RUN_DIR is known.

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
# Package management — Linux only.
# On macOS curl/git/unzip ship with the OS; brew handles extras.
# ─────────────────────────────────────────────────────────────────
check_and_install_packages() {
    if [ "$PLATFORM" = "darwin" ]; then
        return   # macOS: prerequisites assumed present (curl/git/unzip are stock)
    fi
    for package in "$@"; do
        if ! dpkg -l | grep -q "ii  $package"; then
            echo "$package is not installed. Installing $package..."
            apt install -y "$package"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────
# Docker — platform-dispatch wrappers.
# macOS implementations are in mac_helpers.sh; Linux in linux_helpers.sh.
# ─────────────────────────────────────────────────────────────────
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
# Oracle Instant Client — platform-dispatch wrapper.
# macOS implementation in mac_helpers.sh; Linux in linux_helpers.sh.
# ─────────────────────────────────────────────────────────────────
install_oracle_instant_client() {
    if [ "$PLATFORM" = "darwin" ]; then
        _install_oc_mac
    else
        _install_oc_linux
    fi
}

# ─────────────────────────────────────────────────────────────────
# Oracle Container Registry login — optional
# (free-tier GHCR images are accessible without credentials)
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
# macOS implementation in mac_helpers.sh; Linux in linux_helpers.sh.
# ─────────────────────────────────────────────────────────────────
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
        if colima status &>/dev/null; then
            echo "   Colima already running — reuse existing VM"
            if k3s_is_running_mac 2>/dev/null; then
                local _pc
                _pc=$(k3s_app_pod_count_mac 2>/dev/null || echo "?")
                echo "   k3s running ($_pc app pods) — will be stopped to free memory for Oracle ADB"
            else
                echo "   k3s already stopped"
            fi
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
    # Config is adb/.env (was config.ini); fall back to config.ini for old checkouts.
    CONFIG_FILE="$RUN_DIR/.env"; [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$RUN_DIR/config.ini"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file .env (or config.ini) not found in $RUN_DIR. Exiting."
        exit 1
    fi

    HOSTNAME=$(ini_val HOSTNAME)
    DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD)
    ORACLE_REGISTRY_USER=$(ini_val ORACLE_REGISTRY_USER)
    ORACLE_REGISTRY_PASSWORD=$(ini_val ORACLE_REGISTRY_PASSWORD)
    # select_docker_image (common.sh) resolves DOCKER_IMAGE_ARM/_AMD for the effective
    # arch, same logic run-adb-26ai.sh uses — keeps the two scripts' image choice in sync.
    DOCKER_IMAGE="$(select_docker_image)"
    CONTAINER_RUNTIME=$(ini_val CONTAINER_RUNTIME)
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
    COLIMA_ARCH=$(ini_val COLIMA_ARCH);           COLIMA_ARCH="${COLIMA_ARCH:-x86_64}"
    COLIMA_VM_TYPE=$(ini_val COLIMA_VM_TYPE);     COLIMA_VM_TYPE="${COLIMA_VM_TYPE:-vz}"
    COLIMA_VZ_ROSETTA=$(ini_val COLIMA_VZ_ROSETTA); COLIMA_VZ_ROSETTA="${COLIMA_VZ_ROSETTA:-true}"
    COLIMA_MEMORY=$(ini_val COLIMA_MEMORY);       COLIMA_MEMORY="${COLIMA_MEMORY:-8}"
    COLIMA_DISK=$(ini_val COLIMA_DISK);           COLIMA_DISK="${COLIMA_DISK:-100}"

    BASIC_ZIP="$(platform_val BASIC_ZIP)"
    SQLPLUS_ZIP="$(platform_val SQLPLUS_ZIP)"
    BASIC_URL="$(platform_val BASIC_URL)"
    SQLPLUS_URL="$(platform_val SQLPLUS_URL)"
    INSTANT_CLIENT="$(resolve_instant_client)"

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

# Source common utilities (detect_platform, ini_val, platform_val, select_docker_image,
# resolve_instant_client, avail_kb_for_dir, colour helpers) before anything else runs.
# shellcheck source=common.sh
source "$RUN_DIR/common.sh"
detect_platform

# Source platform-specific helpers.
# macOS helpers require CONTAINER_RUNTIME which read_config sets, so we set a
# temporary early value here (same pattern as run-adb-26ai.sh).
if [ "$PLATFORM" = "darwin" ]; then
    _early_cfg="$RUN_DIR/.env"; [ -f "$_early_cfg" ] || _early_cfg="$RUN_DIR/config.ini"
    CONTAINER_RUNTIME=$(grep -m1 "^CONTAINER_RUNTIME=" "$_early_cfg" 2>/dev/null \
                        | cut -d'=' -f2- | tr -d ' \n\r')
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
    # shellcheck source=mac_helpers.sh
    source "$RUN_DIR/mac_helpers.sh"
else
    # shellcheck source=linux_helpers.sh
    source "$RUN_DIR/linux_helpers.sh"
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

# macOS: stop k3s inside the Colima VM if it is still running.
# k3s (mifos-gazelle) consumes 6-8 GB that Oracle ADB needs.
# Colima keeps running; k3s can be re-enabled later with start_k3s_mac.
if [ "$PLATFORM" = "darwin" ] && k3s_is_running_mac 2>/dev/null; then
    echo "k3s detected inside Colima — stopping to free memory for Oracle ADB..."
    stop_k3s_mac
fi

if [ "$PLATFORM" = "linux" ]; then
    oracle_os_user_setup
fi
install_oracle_instant_client
oracle_registry_login
# install_ollama
# launch_ollama_model

echo
echo "Setup for Oracle ADB-Free 26ai completed."
echo "Next step: run ./run-adb-26ai.sh to start the database"
