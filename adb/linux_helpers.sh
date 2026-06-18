#!/usr/bin/env bash
# linux_helpers.sh — Ubuntu-specific Docker, Oracle OS user, and Instant Client helpers.
# Sourced by setup-for-adb-26ai.sh and run-adb-26ai.sh on Linux (Ubuntu 22/24).
# Requires: PLATFORM, SUDO_USER_NAME, SUDO_USER_HOME_DIR, CONFIG_FILE, ini_val() already available.

# ─────────────────────────────────────────────────────────────────
# Docker — install and ensure running on Ubuntu
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

# ─────────────────────────────────────────────────────────────────
# Oracle OS user/group setup — required by Oracle container images
# ─────────────────────────────────────────────────────────────────
oracle_os_user_setup() {
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
# Oracle Instant Client — Linux x86_64
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

    # Ubuntu 24 renamed the package and library; Ubuntu 22 uses the original names.
    local UBUNTU_VER
    UBUNTU_VER=$(lsb_release -rs | cut -d. -f1)
    if [ "$UBUNTU_VER" -ge 24 ]; then
        apt-get install -y libaio1t64
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1t64"
    else
        apt-get install -y libaio1
        LIBAIO_TARGET="/usr/lib/x86_64-linux-gnu/libaio.so.1.0.1"
    fi
    local LIBAIO_LINK="/usr/lib/x86_64-linux-gnu/libaio.so.1"
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

# ─────────────────────────────────────────────────────────────────
# Ollama — Linux install
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
