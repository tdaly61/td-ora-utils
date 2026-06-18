#!/usr/bin/env bash
# mac_helpers.sh — macOS/Colima Docker and Instant Client helpers.
# Sourced by run-adb-26ai.sh and setup-for-adb-26ai.sh on Darwin.
# Requires: PLATFORM, CONFIG_FILE, and ini_val() already available.
#
# Only Colima is supported as the container runtime on macOS.
# If Docker Desktop, Rancher Desktop, or OrbStack is running, the scripts
# exit with a message to shut it down first.
#
# k3s co-existence: mifos-gazelle starts Colima with --kubernetes. When running
# Oracle ADB, k3s competes for memory (6-8 GB). Use stop_k3s_mac / start_k3s_mac
# (or run-adb-26ai.sh -k) to pause k3s without restarting Colima.

# ─────────────────────────────────────────────────────────────────
# k3s helpers — pause/resume Kubernetes inside the Colima VM so that
# Oracle ADB gets the memory it needs without restarting Colima.
# ─────────────────────────────────────────────────────────────────

# Returns 0 if k8s containers are present in the Docker daemon, 1 otherwise.
# DOCKER_HOST is already set to the Colima socket by set_docker_host_mac —
# call docker directly rather than going through colima ssh.
k3s_is_running_mac() {
    local count
    count=$(docker ps -q --filter "label=io.kubernetes.pod.namespace" 2>/dev/null \
            | wc -l | tr -d ' ')
    [ "${count:-0}" -gt 0 ]
}

# Count application (non-kube-system) k8s containers in Docker.
k3s_app_pod_count_mac() {
    docker ps \
        --filter "label=io.kubernetes.pod.namespace" \
        --format '{{.Label "io.kubernetes.pod.namespace"}}' 2>/dev/null \
        | grep -v "^kube-system$" | grep -v "^$" | wc -l | tr -d ' ' || echo 0
}

# Stop k3s inside the Colima VM. Colima and Docker keep running.
# Order matters: disable+stop the systemd unit FIRST so Restart= cannot fire,
# then run k3s-killall.sh for full cleanup, then force-remove any survivors.
stop_k3s_mac() {
    local k8s_count
    k8s_count=$(docker ps -q --filter "label=io.kubernetes.pod.namespace" 2>/dev/null \
                | wc -l | tr -d ' ')

    if [ "${k8s_count:-0}" -eq 0 ]; then
        echo "No k8s containers in Docker — k3s already stopped."
        return
    fi

    echo "Found $k8s_count k8s container(s) — stopping k3s..."

    # 1. Disable + stop the systemd unit BEFORE killing anything.
    #    This prevents systemd's Restart= from respawning k3s after kill.
    colima ssh -- sudo systemctl disable k3s 2>/dev/null || true
    colima ssh -- sudo systemctl stop k3s    2>/dev/null || true

    # 2. k3s-killall.sh cleans up containers, mounts, and network interfaces.
    colima ssh -- sudo k3s-killall.sh >/dev/null 2>&1 || true

    # 3. Force-remove any Docker containers that survived the above.
    local survivors
    survivors=$(docker ps -aq --filter "label=io.kubernetes.pod.namespace" 2>/dev/null)
    if [ -n "$survivors" ]; then
        echo "$survivors" | xargs docker rm -f 2>/dev/null || true
    fi

    sleep 2
    local after
    after=$(docker ps -q --filter "label=io.kubernetes.pod.namespace" 2>/dev/null \
            | wc -l | tr -d ' ')
    echo "k3s stopped and disabled. k8s containers remaining: ${after:-0}"
    echo "  To restore k3s:      colima ssh -- sudo systemctl enable k3s && sudo systemctl start k3s"
    echo "  To redeploy gazelle: sudo ./run.sh -u \$USER -m deploy -a all"
}

# Start k3s inside the Colima VM (after it was stopped by stop_k3s_mac).
start_k3s_mac() {
    if k3s_is_running_mac; then
        echo "k3s is already running."
        return
    fi
    if ! docker info &>/dev/null 2>&1; then
        echo "ERROR: Docker (Colima) is not reachable. Start Colima first."
        return 1
    fi
    echo "Starting k3s inside Colima VM..."
    colima ssh -- sudo systemctl enable k3s 2>/dev/null || true
    colima ssh -- sudo systemctl start k3s
    echo "k3s started. Redeploy mifos-gazelle with: sudo ./run.sh -u \$USER -m deploy -a all"
}

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
# Oracle Instant Client — macOS ARM64 (M1/M2/M3/M4)
# ─────────────────────────────────────────────────────────────────

# Mount a DMG, run its install_ic.sh, then detach.
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

# ─────────────────────────────────────────────────────────────────
# Ollama — macOS install
# ─────────────────────────────────────────────────────────────────
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
