#!/usr/bin/env bash
# mac_helpers.sh — macOS/Colima Docker helpers.
# Sourced by run-adb-26ai.sh and setup-for-adb-26ai.sh on Darwin.
# Requires: PLATFORM, CONFIG_FILE, and ini_val() already available.
#
# Only Colima is supported as the container runtime on macOS.
# If Docker Desktop, Rancher Desktop, or OrbStack is running, the scripts
# exit with a message to shut it down first.

# ─────────────────────────────────────────────────────────────────
# check_no_conflicting_runtime_mac — exit if a non-Colima Docker
# runtime is running. Call this before any docker command.
# ─────────────────────────────────────────────────────────────────
check_no_conflicting_runtime_mac() {
    local conflict=""

    if pgrep -xq "Docker Desktop" 2>/dev/null || \
       pgrep -f "Docker\.app/Contents/MacOS" &>/dev/null 2>&1; then
        conflict="Docker Desktop"
    fi

    if [ -z "$conflict" ] && \
       (pgrep -xq "Rancher Desktop" 2>/dev/null || \
        pgrep -f "Rancher Desktop\.app" &>/dev/null 2>&1); then
        conflict="Rancher Desktop"
    fi

    if [ -z "$conflict" ] && \
       (pgrep -xq "OrbStack" 2>/dev/null || \
        pgrep -f "OrbStack\.app" &>/dev/null 2>&1); then
        conflict="OrbStack"
    fi

    if [ -n "$conflict" ]; then
        echo ""
        echo "ERROR: $conflict is running."
        echo "       This project uses Colima exclusively as its Docker runtime."
        echo "       Shut down $conflict, then re-run."
        echo ""
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────
# set_docker_host_mac — call once at script start on macOS, before
# any docker command, to point the CLI at the Colima socket.
# ─────────────────────────────────────────────────────────────────
set_docker_host_mac() {
    check_no_conflicting_runtime_mac
    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
    # Pin DOCKER_API_VERSION if CLI is newer than the Colima-hosted daemon.
    _fix_docker_api_version_mac
}

# ─────────────────────────────────────────────────────────────────
# _fix_docker_api_version_mac — if the docker CLI reports an API
# version mismatch, pin DOCKER_API_VERSION to what the server accepts.
# ─────────────────────────────────────────────────────────────────
_fix_docker_api_version_mac() {
    local err
    err=$(docker info 2>&1) || true
    if echo "$err" | grep -q "client version.*too new"; then
        local max_ver
        max_ver=$(echo "$err" | grep -oE "Maximum supported API version is [0-9.]+" | grep -oE "[0-9.]+$")
        if [ -n "$max_ver" ]; then
            echo "Docker API version mismatch — pinning DOCKER_API_VERSION=$max_ver"
            export DOCKER_API_VERSION="$max_ver"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────
# install_docker_mac — install Colima + Docker CLI via Homebrew.
# Called from setup-for-adb-26ai.sh only.
# ─────────────────────────────────────────────────────────────────
install_docker_mac() {
    if command -v colima &>/dev/null && command -v docker &>/dev/null; then
        echo "Colima $(colima version 2>/dev/null | head -1) and Docker CLI already installed."
        return
    fi
    if ! command -v brew &>/dev/null; then
        echo "ERROR: Homebrew is required to install Colima."
        echo "       Install Homebrew first: https://brew.sh"
        exit 1
    fi
    echo "Installing Colima and Docker CLI via Homebrew..."
    brew install colima docker
    echo "Colima and Docker CLI installed."
}

# ─────────────────────────────────────────────────────────────────
# check_docker_installed_mac — verify Colima binary and Docker CLI
# are present. Does NOT start any daemon.
# ─────────────────────────────────────────────────────────────────
check_docker_installed_mac() {
    local missing=0
    if ! command -v colima &>/dev/null; then
        echo "ERROR: colima not found."
        missing=1
    fi
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker CLI not found."
        missing=1
    fi
    if [ "$missing" -eq 1 ]; then
        echo "Run: sudo ./setup-for-adb-26ai.sh   (installs Colima + Docker CLI via Homebrew)"
        exit 1
    fi
    echo "Colima and Docker CLI found."
}

# ─────────────────────────────────────────────────────────────────
# ensure_docker_running_mac — start Colima if not already running.
#   Case 1: VM already running  → reuse (shared with mifos-gazelle)
#   Case 2: VM stopped          → colima start (restarts existing VM)
#   Case 3: No VM yet           → colima start (creates + starts VM)
# Sizing flags (arch, memory, disk) only apply when creating a new VM;
# colima ignores them when the VM already exists.
# ─────────────────────────────────────────────────────────────────
ensure_docker_running_mac() {
    if ! command -v colima &>/dev/null; then
        echo "ERROR: colima not found. Run: sudo ./setup-for-adb-26ai.sh"
        exit 1
    fi

    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"

    # Case 1: already running — reuse (may be shared with mifos-gazelle)
    if colima status 2>/dev/null | grep -q "Running"; then
        echo "Colima already running — reusing existing VM."
        _fix_docker_api_version_mac
        return
    fi

    # Case 2 / 3: stopped or no VM — colima start handles both
    local arch mem disk vm_type rosetta flags
    arch=$(ini_val COLIMA_ARCH 2>/dev/null);          arch="${arch:-x86_64}"
    mem=$(ini_val COLIMA_MEMORY 2>/dev/null);         mem="${mem:-8}"
    disk=$(ini_val COLIMA_DISK 2>/dev/null);          disk="${disk:-100}"
    vm_type=$(ini_val COLIMA_VM_TYPE 2>/dev/null);    vm_type="${vm_type:-vz}"
    rosetta=$(ini_val COLIMA_VZ_ROSETTA 2>/dev/null); rosetta="${rosetta:-true}"

    flags="--arch $arch --memory $mem --disk $disk --runtime docker"
    [ "$vm_type" = "vz" ] && flags="$flags --vm-type vz"
    [ "$vm_type" = "vz" ] && [ "$rosetta" = "true" ] && flags="$flags --vz-rosetta"

    echo "Starting Colima ($flags)..."
    # shellcheck disable=SC2086
    if ! colima start $flags; then
        echo "ERROR: Colima failed to start."
        exit 1
    fi

    export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
    local i
    for i in {1..24}; do
        sleep 5
        if docker info &>/dev/null 2>&1; then
            echo "Colima is running."
            _fix_docker_api_version_mac
            return
        fi
        echo "  Still waiting for Colima... ($((i * 5))s)"
    done
    echo "ERROR: Colima did not become ready within 120 seconds."
    exit 1
}
