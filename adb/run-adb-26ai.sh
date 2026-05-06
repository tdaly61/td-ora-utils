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
}

# Read a single KEY=VALUE entry from CONFIG_FILE by exact key name.
# Handles values containing '=' (e.g. URLs). Strips surrounding whitespace.
ini_val() {
    local key="$1"
    grep -m1 "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2- | tr -d ' \n\r'
}

# Check if a container exists and is healthy/running. Returns:
#   0 — container is running (reuse it)
#   1 — container does not exist or was removed (create it)
check_container_state() {
    local name="$1"
    local cid
    cid=$(docker ps -aq -f "name=^${name}$" 2>/dev/null || true)
    if [ -z "$cid" ]; then
        return 1  # does not exist
    fi
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
    if [ "$state" = "running" ]; then
        return 0  # running
    fi
    # Exists but stopped/dead — remove so we can recreate cleanly
    echo "Container $name exists but is $state — removing stale container..."
    docker rm -f "$name" >/dev/null 2>&1 || true
    return 1  # treat as not existing
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
    echo "Stopping and removing ADB container..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true

    echo "Do you want to remove the database data directory $HOME/db_data_dir? (y/n): "
    read -t 30 choice || choice="n"
    case "$choice" in
        y|Y)
            echo "Removing database data directory $HOME/db_data_dir..."
            sudo rm -rf "$HOME/db_data_dir"
            ;;
        *)
            echo "Skipping database data directory removal."
            ;;
    esac

    if [ "$REMOVE_IMAGES" = "true" ]; then
        echo "Removing Docker image $DOCKER_IMAGE..."
        docker rmi "$DOCKER_IMAGE" 2>/dev/null || true
    else
        echo "Docker image retained (use -r flag to also remove image)."
    fi

    echo "Cleanup complete."
    exit 0
}

usage() {
    echo "Usage: $0 [-c [-r]] | -h"
    echo "Options:"
    echo "  -c     Cleanup: stop and remove ADB container, prompt to remove data dir"
    echo "  -r     Also remove Docker image (only valid with -c; default: image is kept)"
    echo "  -h     Display this help"
    exit 1
}

create_db_data_dir() {
    if [ ! -d "$HOME/db_data_dir" ]; then
        echo "Creating db_data_dir directory at $HOME/db_data_dir..."
        mkdir -p "$HOME/db_data_dir"
        chmod 777 "$HOME/db_data_dir"
    fi
}

print_elapsed_time() {
    local SECONDS=$1
    local HOURS=$((SECONDS / 3600))
    local MINUTES=$(( (SECONDS % 3600) / 60 ))
    local SECONDS=$((SECONDS % 60))
    printf "%02d:%02d:%02d\n" $HOURS $MINUTES $SECONDS
}

wait_for_container_healthy() {
    TIMEOUT=$1
    echo "Waiting for [ $TIMEOUT ] secs the container $CONTAINER_NAME to be in a running and healthy state..."

    START_TIME=$(date +%s)
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

        if [ "$ELAPSED_TIME" -ge "$TIMEOUT" ]; then
            echo "Timeout of $TIMEOUT seconds reached. Exiting."
            exit 1
        fi

        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
        if [ "$STATUS" = "healthy" ]; then
            echo "Container $CONTAINER_NAME is running and healthy."
            break
        elif [ "$STATUS" = "unhealthy" ]; then
            echo "Container $CONTAINER_NAME is unhealthy. Exiting."
            exit 1
        else
            echo "Container $CONTAINER_NAME is not yet healthy. Current status: $STATUS. Waiting..."
            echo "Elapsed time: $(print_elapsed_time $ELAPSED_TIME)"
            sleep 15
        fi
    done

    TOTAL_TIME=$((CURRENT_TIME - START_TIME))
    echo "Total time taken: $(print_elapsed_time $TOTAL_TIME)"
}

get_model() {
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Downloading ONNX model from $ONNX_MODEL_URL... to $MODEL_PATH"
        if ! curl -fL -C - -o "$MODEL_PATH" "$ONNX_MODEL_URL"; then
            echo "Failed to download the ONNX model. Exiting."
            rm -f "$MODEL_PATH"  # remove partial download
            exit 1
        fi
        echo "ONNX model downloaded and saved to $MODEL_PATH."
    else
        echo "ONNX model already exists at $MODEL_PATH. Skipping download."
    fi
}

# Copy TLS wallet from the running container so sqlplus can connect via mTLS.
# Sets WALLET_DIR for use by run_sql_file and exported TNS_ADMIN.
configure_sql_access() {
    echo "Copying TLS wallet from container for sqlplus access..."
    AUTH_DIR="$HOME/auth"

    if [ -d "$AUTH_DIR" ] && [ ! -w "$AUTH_DIR" ]; then
        sudo rm -rf "$AUTH_DIR"
    else
        rm -rf "$AUTH_DIR"
    fi
    mkdir -p "$AUTH_DIR"

    docker cp "${CONTAINER_NAME}:/u01/app/oracle/wallets/tls_wallet/" "$AUTH_DIR/"
    WALLET_DIR="$AUTH_DIR/tls_wallet"
    echo "TLS wallet copied to $WALLET_DIR"
}

run_sql_file() {
    local sql_file="$1"
    local user="${2:-admin}"

    if [ ! -f "$sql_file" ]; then
        echo "SQL file $sql_file does not exist. Skipping."
        return 1
    fi
    echo "Running SQL file $sql_file as $user..."
    if ! TNS_ADMIN="$WALLET_DIR" \
         LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
         DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
             "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus" -s "$user/$DEFAULT_PASSWORD@$SERVICE_NAME" "@$sql_file"; then
        echo "Failed to execute SQL file $sql_file."
        return 1
    fi
    echo "SQL file $sql_file executed successfully."
}

# Enable MAX_STRING_SIZE=EXTENDED so VARCHAR2(32767) columns are supported.
# ADB-Free typically has this enabled by default — the check will return early.
enable_extended_string_size() {
    echo "=== Checking MAX_STRING_SIZE ==="

    local current
    current=$(docker exec -i "$CONTAINER_NAME" sqlplus -s / as sysdba << 'SQLEOF' 2>/dev/null
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT value FROM v$parameter WHERE name='max_string_size';
EXIT;
SQLEOF
)
    current=$(echo "$current" | tr -d '[:space:]')

    if [ "${current^^}" = "EXTENDED" ]; then
        echo "MAX_STRING_SIZE already EXTENDED — skipping."
        return 0
    fi

    echo "MAX_STRING_SIZE=$current — enabling EXTENDED (DB will restart in UPGRADE mode)..."

    # Step 1: Set parameter and restart CDB in UPGRADE mode
    docker exec -i "$CONTAINER_NAME" sqlplus -s / as sysdba << 'SQLEOF'
ALTER SYSTEM SET MAX_STRING_SIZE=EXTENDED SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP UPGRADE;
EXIT;
SQLEOF

    # Step 2: Run utl32k.sql in CDB root and each PDB
    docker exec -i "$CONTAINER_NAME" sqlplus -s / as sysdba << 'SQLEOF'
@?/rdbms/admin/utl32k.sql
ALTER PLUGGABLE DATABASE ALL OPEN UPGRADE;
ALTER SESSION SET CONTAINER=MYATP;
@?/rdbms/admin/utl32k.sql
ALTER SESSION SET CONTAINER=CDB$ROOT;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQLEOF

    echo "MAX_STRING_SIZE=EXTENDED enabled — waiting for DB to stabilise..."
    sleep 20
    wait_for_container_healthy 300
    echo "MAX_STRING_SIZE=EXTENDED configured successfully."
}

generate_sql_files() {
    local TPL="$RUN_DIR/sql-scripts/create-users.sql.tpl"
    local OUT="$RUN_DIR/sql-scripts/create-users.sql"
    if [ ! -f "$TPL" ]; then
        echo "Template $TPL not found. Exiting."
        exit 1
    fi
    sed -e "s/__APEX_USER__/$APEX_USER/g" \
        -e "s/__APEX_PASSWORD__/$APEX_PASSWORD/g" \
        "$TPL" > "$OUT"
}

# Start the ADB-Free 26ai single container (ORDS and APEX are pre-installed).
run_adb() {
    echo "Starting ADB container from $DOCKER_IMAGE..."
    docker run -d \
        -p 1521:1522 \
        -p 1522:1522 \
        -p 8443:8443 \
        -p 27017:27017 \
        -e WORKLOAD_TYPE='ATP' \
        -e WALLET_PASSWORD="$DEFAULT_PASSWORD" \
        -e ADMIN_PASSWORD="$DEFAULT_PASSWORD" \
        --hostname "$HOSTNAME" \
        --cap-add SYS_ADMIN \
        --device /dev/fuse \
        --volume "$HOME/db_data_dir":/u01/data \
        --name "$CONTAINER_NAME" \
        "$DOCKER_IMAGE"
}

# ─────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────
preflight_check() {
    local errors=0
    echo "--- Pre-flight checks ---"

    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker not found. Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    elif ! docker info &>/dev/null 2>&1; then
        if [ "$PLATFORM" = "darwin" ]; then
            echo "ERROR: Docker daemon not running. Start Colima or run: sudo ./setup-for-adb-26ai.sh"
        elif sudo systemctl is-active --quiet docker 2>/dev/null; then
            echo "ERROR: Docker is running but not accessible. Log out and back in, or re-run with sudo."
        else
            echo "ERROR: Docker is not running. Run: sudo systemctl start docker"
        fi
        errors=$((errors + 1))
    fi

    if [ ! -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
        echo "ERROR: Instant Client not found at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
        echo "       Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    fi

    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1; then
        echo "Note: Oracle image not cached locally — will pull from container-registry.oracle.com."
    fi

    local avail_kb
    avail_kb=$(avail_kb_for_dir "$HOME")
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 15728640 ]; then  # 15 GB
        echo "WARNING: Less than 15 GB free in $HOME — Oracle container may run out of space."
    fi

    if [ "$errors" -gt 0 ]; then
        echo "--- $errors pre-flight error(s). Fix the above before continuing. ---"
        exit 1
    fi
    echo "--- Pre-flight checks passed ---"
}

# ─────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────
read_config() {
    CONFIG_FILE="$RUN_DIR/config.ini"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file config.ini not found in $RUN_DIR. Exiting."
        exit 1
    fi

    HOSTNAME=$(ini_val HOSTNAME)
    DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD | tr -d '\n\r')
    CONTAINER_NAME=$(ini_val CONTAINER_NAME)
    DOCKER_IMAGE=$(ini_val DOCKER_IMAGE)
    ONNX_MODEL_URL=$(ini_val ONNX_MODEL_URL)
    ORACLE_REGISTRY_USER=$(ini_val ORACLE_REGISTRY_USER)
    ORACLE_REGISTRY_PASSWORD=$(ini_val ORACLE_REGISTRY_PASSWORD)
    SERVICE_NAME=$(ini_val SERVICE_NAME)
    APEX_PORT=$(ini_val APEX_PORT)
    APEX_PORT=${APEX_PORT:-8443}
    APEX_USER=$(ini_val APEX_USER)
    APEX_USER=${APEX_USER:-TRACKER1}
    APEX_PASSWORD=$(ini_val APEX_PASSWORD | tr -d '\n\r')
    APEX_PASSWORD=${APEX_PASSWORD:-$DEFAULT_PASSWORD}
    CONTAINER_RUNTIME=$(ini_val CONTAINER_RUNTIME)
    CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-auto}

    if [ "$PLATFORM" = "darwin" ]; then
        # Mac: prefer *_MAC keys, fall back to generic keys if Mac-specific ones are absent
        SQLPLUS_URL=$(ini_val SQLPLUS_URL_MAC)
        INSTANT_CLIENT=$(ini_val INSTANT_CLIENT_MAC)
        [ -z "$SQLPLUS_URL" ]    && SQLPLUS_URL=$(ini_val SQLPLUS_URL)
        [ -z "$INSTANT_CLIENT" ] && INSTANT_CLIENT=$(ini_val INSTANT_CLIENT)
    else
        SQLPLUS_URL=$(ini_val SQLPLUS_URL)
        INSTANT_CLIENT=$(ini_val INSTANT_CLIENT)
    fi

    local missing=""
    [ -z "$SQLPLUS_URL" ]      && missing="$missing SQLPLUS_URL"
    [ -z "$INSTANT_CLIENT" ]   && missing="$missing INSTANT_CLIENT"
    [ -z "$HOSTNAME" ]         && missing="$missing HOSTNAME"
    [ -z "$DEFAULT_PASSWORD" ] && missing="$missing DEFAULT_PASSWORD"
    [ -z "$CONTAINER_NAME" ]   && missing="$missing CONTAINER_NAME"
    [ -z "$DOCKER_IMAGE" ]     && missing="$missing DOCKER_IMAGE"
    [ -z "$SERVICE_NAME" ]     && missing="$missing SERVICE_NAME"
    if [ -n "$missing" ]; then
        echo "Missing required config.ini values:$missing"
        exit 1
    fi
}

####### main #######
PLATFORM=""
ARCH=""
WALLET_DIR=""
TNS_ADMIN=""
ORACLE_CLIENT_DIR="$HOME/oraclient"
MODEL_PATH="$HOME/model.onnx"
REMOVE_IMAGES=false
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

detect_platform

if [ "$PLATFORM" = "darwin" ]; then
    # Source mac_helpers.sh and set the correct Docker socket/context before any docker call.
    # shellcheck source=mac_helpers.sh
    source "$RUN_DIR/mac_helpers.sh"
    # Read CONTAINER_RUNTIME early (before full read_config) so set_docker_host_mac gets the right value.
    CONTAINER_RUNTIME=$(grep -m1 "^CONTAINER_RUNTIME=" "$RUN_DIR/config.ini" 2>/dev/null | cut -d'=' -f2- | tr -d ' \n\r')
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
    set_docker_host_mac
fi

# On Linux: if docker isn't accessible, try to apply the docker group without requiring a logout.
# We check /etc/group (via id -nG) rather than the current session's groups,
# because this session may predate the docker group add done by setup-for-adb-26ai.sh.
if [ "$PLATFORM" = "linux" ]; then
    if ! docker info &>/dev/null 2>&1; then
        _current_user="${SUDO_USER:-$USER}"
        if id -nG "$_current_user" 2>/dev/null | grep -qw docker; then
            echo "Docker group not active in this session — re-launching in docker group context..."
            exec sg docker -c "bash $(printf '%q ' "$0" "$@")"
        fi
        unset _current_user
    fi

    # sg disconnects stdin from the TTY. Reconnect so interactive prompts work correctly.
    [ ! -t 0 ] && exec < /dev/tty 2>/dev/null || true
fi

read_config

DO_CLEANUP=false
while getopts "hcr" opt; do
    case ${opt} in
        h ) usage ;;
        c ) DO_CLEANUP=true ;;
        r ) REMOVE_IMAGES=true ;;
        \? ) usage ;;
    esac
done

if [ "$DO_CLEANUP" = "true" ]; then
    cleanup
fi

preflight_check

create_db_data_dir

ADB_ALREADY_RUNNING=false
if check_container_state "$CONTAINER_NAME"; then
    echo "Container $CONTAINER_NAME is already running — reusing."
    ADB_ALREADY_RUNNING=true
else
    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1; then
        echo "Pulling Oracle image $DOCKER_IMAGE (15-20 GB first pull — may take a while)..."
        if [ -n "${ORACLE_REGISTRY_USER:-}" ] && [ -n "${ORACLE_REGISTRY_PASSWORD:-}" ]; then
            echo "$ORACLE_REGISTRY_PASSWORD" | docker login container-registry.oracle.com \
                -u "$ORACLE_REGISTRY_USER" --password-stdin
        fi
        if ! docker pull "$DOCKER_IMAGE"; then
            echo "ERROR: Image pull failed. Ensure you can reach container-registry.oracle.com"
            echo "       and have accepted the licence at https://container-registry.oracle.com"
            exit 1
        fi
    fi
    run_adb
    wait_for_container_healthy 1800
fi

get_model

if [ "$ADB_ALREADY_RUNNING" = "false" ]; then
    sleep 30
fi

configure_sql_access
export TNS_ADMIN="$WALLET_DIR"
echo "TNS_ADMIN is $TNS_ADMIN"

# Copy ONNX model into the container for Oracle Vector Search embedding
echo "Copying ONNX model into container..."
docker cp "$MODEL_PATH" "$CONTAINER_NAME:/u01/data/dpdump/model.onnx"

# Enable extended VARCHAR2(32767) support — ADB-Free typically has this already; will be a no-op.
enable_extended_string_size

generate_sql_files
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" admin
run_sql_file "$RUN_DIR/sql-scripts/vector-setup.sql" admin

echo "Configuring LLM integration..."
run_sql_file "$RUN_DIR/sql-scripts/setup-ollama-ai.sql" admin || true

echo ""
echo "=== Setup complete ==="
echo "1. DB logs:    docker logs -f $CONTAINER_NAME"
echo "2. NOT SECURE: for Demo and POC use only"
echo "3. APEX:       https://localhost:$APEX_PORT/ords/apex  (accept self-signed cert on first visit)"
echo "   APEX admin: Workspace=internal  User=ADMIN  Password=$DEFAULT_PASSWORD"
echo "4. sqlplus:    TNS_ADMIN=$HOME/auth/tls_wallet $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus admin/$DEFAULT_PASSWORD@$SERVICE_NAME"
echo "5. SSH tunnel: ssh -L $APEX_PORT:localhost:$APEX_PORT -N ubuntu@<server-ip>"
_ollama_cfg=$(ini_val LLM_OLLAMA_LOCAL 2>/dev/null || true)
if [ -n "${_ollama_cfg:-}" ]; then
    OLLAMA_BASE_URL="${_ollama_cfg%%|*}"
    OLLAMA_MODEL="$(echo "$_ollama_cfg" | awk -F'|' '{print $2}')"
    echo "6. Ollama:     $OLLAMA_BASE_URL (model: $OLLAMA_MODEL)"
    echo "   Test SQL:   SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT('Hello', JSON('{\"provider\":\"ollama\",\"host\":\"$OLLAMA_BASE_URL\",\"model\":\"$OLLAMA_MODEL\"}')) FROM dual;"
fi
