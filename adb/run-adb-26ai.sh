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
    generate_env_file

    echo "Stopping and removing containers via docker compose..."
    docker compose -f "$RUN_DIR/docker-compose.yml" --env-file "$RUN_DIR/.env" down 2>/dev/null || {
        echo "Compose down failed, falling back to direct docker stop..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
        docker stop ords >/dev/null 2>&1
        docker rm ords >/dev/null 2>&1
    }

    # ORDS config is kept by default so credentials survive across restarts.
    # Clearing it without also wiping the DB causes ORA-01017 (ORDS_PUBLIC_USER
    # password mismatch). Only clear when the DB data dir is also being removed.
    echo "Do you want to remove the database data directory $HOME/db_data_dir? (y/n): "
    read -t 30 choice || choice="n"
    case "$choice" in
        y|Y )
            echo "Removing database data directory $HOME/db_data_dir..."
            sudo rm -rf "$HOME/db_data_dir"
            echo "Clearing ORDS config (DB removed, so credentials no longer valid)..."
            sudo rm -rf "$RUN_DIR/ords_config" && mkdir -p "$RUN_DIR/ords_config" && chmod 777 "$RUN_DIR/ords_config"
            ;;
        n|N )
            echo "Skipping database data directory removal."
            ;;
        * )
            echo "Invalid choice. Skipping database data directory removal."
            ;;
    esac

    if [ "$REMOVE_IMAGES" = "true" ]; then
        echo "Removing Docker images..."
        docker compose -f "$RUN_DIR/docker-compose.yml" --env-file "$RUN_DIR/.env" down --rmi all 2>/dev/null || true
    else
        echo "Docker images retained (use -r flag to also remove images)."
    fi

    echo "Cleanup complete."
    exit 0
}

# ─────────────────────────────────────────────────────────────────
# Container helpers
# ─────────────────────────────────────────────────────────────────
check_existing_container() {
    if [ "$(docker ps -aq -f name=^${CONTAINER_NAME}$)" ]; then
        echo "Container $CONTAINER_NAME already exists. Run ./run-adb-26ai.sh -c to clean up."
        exit 1
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

usage() {
    echo "Usage: $0 [-c [-r]] | -h"
    echo "Options:"
    echo "  -c     Cleanup: stop containers, clear ords_config, prompt to remove data dir"
    echo "  -r     Also remove Docker images (only valid with -c; default: images are kept)"
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

generate_env_file() {
    cat > "$RUN_DIR/.env" << EOF
ORACLE_PWD=${DEFAULT_PASSWORD}
SERVICE_NAME=${SERVICE_NAME}
DOCKER_IMAGE=${DOCKER_IMAGE}
CONTAINER_NAME=${CONTAINER_NAME}
DB_HOSTNAME=${HOSTNAME}
APEX_PORT=${APEX_PORT}
DB_DATA_DIR=${HOME}/db_data_dir
APEX_DIR=${APEX_DIR}
EOF
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
        if [ "$STATUS" == "healthy" ]; then
            echo "Container $CONTAINER_NAME is running and healthy."
            break
        elif [ "$STATUS" == "unhealthy" ]; then
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

# ─────────────────────────────────────────────────────────────────
# ORDS pool.xml patch
#
# ORDS 25.x behaviour in containers:
#   - During install it uses DBHOST/ORACLE_PWD env vars to connect as SYS.
#   - After install it writes pool.xml with only plsql.gateway.mode=proxied
#     (no hostname, no credentials).
#   - At runtime it defaults to localhost:1521 → ORA-12541 → HTTP 571.
#   - Even if the hostname is added to pool.xml, ORDS_PUBLIC_USER has no
#     stored credential and auth fails with ORA-01017 → HTTP 574.
#
# Fix (repeatable):
#   1. Reset ORDS_PUBLIC_USER password in the DB to DEFAULT_PASSWORD.
#   2. Write pool.xml with hostname + ORDS_PUBLIC_USER + DEFAULT_PASSWORD.
# ─────────────────────────────────────────────────────────────────
patch_ords_pool_config() {
    local POOL_XML="$RUN_DIR/ords_config/databases/default/pool.xml"

    echo "Patching ORDS pool.xml (ORDS 25.x does not persist hostname or credentials)..."

    echo "  Resetting ORDS_PUBLIC_USER password in DB..."
    docker exec "$CONTAINER_NAME" bash -c \
        "echo \"ALTER USER ORDS_PUBLIC_USER IDENTIFIED BY \\\"$DEFAULT_PASSWORD\\\";\" | \
         sqlplus -s sys/$DEFAULT_PASSWORD@localhost:1521/$SERVICE_NAME as sysdba" \
        2>/dev/null | grep -v '^$' || echo "  Warning: could not reset ORDS_PUBLIC_USER password."

    docker exec ords rm -f /etc/ords/config/databases/default/pool.xml 2>/dev/null || true
    mkdir -p "$(dirname "$POOL_XML")"
    cat > "$POOL_XML" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
<properties>
<entry key="db.hostname">oracle-db</entry>
<entry key="db.port">1521</entry>
<entry key="db.servicename">${SERVICE_NAME}</entry>
<entry key="db.username">ORDS_PUBLIC_USER</entry>
<entry key="db.password">${DEFAULT_PASSWORD}</entry>
<entry key="plsql.gateway.mode">proxied</entry>
</properties>
EOF
    echo "  Pool config written."

    echo "Restarting ORDS container to apply patched pool config..."
    docker restart ords
    sleep 15
}

wait_for_ords() {
    local TIMEOUT=${1:-3600}
    echo "Waiting up to $(print_elapsed_time $TIMEOUT) for ORDS/APEX on port $APEX_PORT..."
    echo "(APEX installation runs inside the ORDS container — allow 30-60 minutes on first run)"
    local START_TIME=$(date +%s)
    local POOL_PATCHED=false
    while true; do
        local CURRENT_TIME=$(date +%s)
        local ELAPSED=$((CURRENT_TIME - START_TIME))
        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "Timeout waiting for ORDS. Check logs with: docker logs ords"
            exit 1
        fi
        local HTTP_CODE
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${APEX_PORT}/ords/apex" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
            echo "ORDS/APEX is ready (HTTP $HTTP_CODE). Total time: $(print_elapsed_time $ELAPSED)"
            break
        fi
        # HTTP 571: ORDS running but DB connection failed (pool.xml missing host). Patch once.
        if [ "$HTTP_CODE" = "571" ] && [ "$POOL_PATCHED" = "false" ]; then
            echo "ORDS returned HTTP 571 (DB connection failed) — patching pool.xml..."
            patch_ords_pool_config
            POOL_PATCHED=true
            continue
        fi
        echo "ORDS not ready yet (HTTP $HTTP_CODE). Elapsed: $(print_elapsed_time $ELAPSED). Waiting..."
        sleep 30
    done
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

configure_sql_access() {
    echo "Configuring SQL access..."
    AUTH_DIR="$HOME/auth"
    TNS_DIR="$AUTH_DIR/tns"

    # Remove previous auth dir — may be root-owned if a prior sudo run created it
    if [ -d "$AUTH_DIR" ] && [ ! -w "$AUTH_DIR" ]; then
        sudo rm -rf "$AUTH_DIR"
    else
        rm -rf "$AUTH_DIR"
    fi
    echo "Creating TNS config directory at $TNS_DIR."
    mkdir -p "$TNS_DIR"

    cat > "$TNS_DIR/tnsnames.ora" << EOF
$SERVICE_NAME =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $SERVICE_NAME)
    )
  )
FREE =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = FREE)
    )
  )
EOF
    WALLET_DIR="$TNS_DIR"
    echo "TNS configuration written to $TNS_DIR/tnsnames.ora"
}

run_sql_file() {
    local sql_file="$1"
    local user="$2"

    if [ ! -f "$sql_file" ]; then
        echo "SQL file $sql_file does not exist. Skipping."
        return 1
    fi
    echo "Running SQL file $sql_file..."
    # Set both LD_LIBRARY_PATH (Linux) and DYLD_LIBRARY_PATH (macOS) — harmless on either platform
    LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
        "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus" -s "$user/$DEFAULT_PASSWORD@$SERVICE_NAME" "@$sql_file"
    if [ $? -ne 0 ]; then
        echo "Failed to execute SQL file $sql_file."
        return 1
    fi
    echo "SQL file $sql_file executed successfully."
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

# ─────────────────────────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────────────────────────
preflight_check() {
    local errors=0
    echo "--- Pre-flight checks ---"

    if ! command -v docker &>/dev/null; then
        if [ "$PLATFORM" = "darwin" ]; then
            echo "ERROR: Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/"
        else
            echo "ERROR: Docker is not installed. Run: sudo ./setup-for-adb-26ai.sh"
        fi
        errors=$((errors + 1))
    elif ! docker info &>/dev/null 2>&1; then
        if [ "$PLATFORM" = "darwin" ]; then
            echo "ERROR: Docker Desktop is not running. Start Docker Desktop and try again."
        elif sudo systemctl is-active --quiet docker 2>/dev/null; then
            echo "ERROR: Docker is running but not accessible. Log out and back in, or re-run with sudo."
        else
            echo "ERROR: Docker is not running. Run: sudo systemctl start docker"
        fi
        errors=$((errors + 1))
    fi

    if ! docker compose version &>/dev/null 2>&1; then
        echo "ERROR: Docker Compose plugin not found. Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    fi

    if [ ! -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
        echo "ERROR: Instant Client not found at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
        echo "       Run: sudo ./setup-for-adb-26ai.sh"  # sudo only needed on Linux
        errors=$((errors + 1))
    fi

    local effective_apex_dir="${APEX_DIR:-$HOME/apex}"
    if [ ! -d "$effective_apex_dir" ] || [ -z "$(ls -A "$effective_apex_dir" 2>/dev/null)" ]; then
        echo "ERROR: APEX directory missing or empty: $effective_apex_dir"
        echo "       Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    fi

    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null || \
       ! docker image inspect container-registry.oracle.com/database/ords:latest &>/dev/null; then
        echo "Note: Oracle images not cached locally — will pull from container-registry.oracle.com (no login required)."
    fi

    local avail_kb
    avail_kb=$(avail_kb_for_dir "$HOME")
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 15728640 ]; then  # 15 GB
        echo "WARNING: Less than 15 GB free in $HOME — Oracle Database container may run out of space."
    fi

    if [ ! -f "$RUN_DIR/docker-compose.yml" ]; then
        echo "ERROR: docker-compose.yml not found in $RUN_DIR"
        errors=$((errors + 1))
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
    APEX_PORT=${APEX_PORT:-8080}
    APEX_DIR=$(ini_val APEX_DIR)
    APEX_DIR=${APEX_DIR:-$HOME/apex}
    APEX_USER=$(ini_val APEX_USER)
    APEX_USER=${APEX_USER:-TRACKER1}
    APEX_PASSWORD=$(ini_val APEX_PASSWORD | tr -d '\n\r')
    APEX_PASSWORD=${APEX_PASSWORD:-$DEFAULT_PASSWORD}

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
[ "$PLATFORM" = "darwin" ] && _resolve_docker_mac

# On Linux: if docker isn't accessible, try to apply the docker group without requiring a logout.
# We check /etc/group (via id -nG) rather than the current session's groups,
# because this session may predate the docker group add done by setup-for-adb-26ai.sh.
# This is Linux-specific — Docker Desktop on Mac handles permissions without group membership.
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

# --- Phase 1: Start Oracle Database ---
create_db_data_dir
generate_env_file

echo "Pulling Docker images (DB + ORDS) — login not required for Oracle free-tier images..."
docker compose -f "$RUN_DIR/docker-compose.yml" --env-file "$RUN_DIR/.env" pull || {
    echo "Warning: image pull failed (registry unreachable or auth required)."
    echo "Checking for locally cached images..."
    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null || \
       ! docker image inspect container-registry.oracle.com/database/ords:latest &>/dev/null; then
        echo "ERROR: Required images not cached locally. Ensure you can reach container-registry.oracle.com"
        echo "       or run: docker login container-registry.oracle.com"
        exit 1
    fi
    echo "Using locally cached images."
}

get_model

if [ "$DB_ALREADY_RUNNING" = "false" ]; then
    sleep 30
fi

configure_sql_access
export TNS_ADMIN="$WALLET_DIR"
echo "TNS_ADMIN is $TNS_ADMIN"

DATA_PUMP_DIR=$(docker exec $CONTAINER_NAME bash -c \
    "echo \"SELECT directory_path FROM dba_directories WHERE directory_name='DATA_PUMP_DIR';\" | \
     sqlplus -s sys/$DEFAULT_PASSWORD@localhost:1521/$SERVICE_NAME as sysdba 2>/dev/null" \
    | grep -E '^/' | head -1 | tr -d '[:space:]') || true
if [ -z "$DATA_PUMP_DIR" ]; then
    DATA_PUMP_DIR="/opt/oracle/admin/FREE/dpdump"
    echo "Warning: could not query DATA_PUMP_DIR, using default: $DATA_PUMP_DIR"
fi
echo "DATA_PUMP_DIR is $DATA_PUMP_DIR"
docker exec "$CONTAINER_NAME" ls -l "$DATA_PUMP_DIR"
echo "===="

docker cp "$MODEL_PATH" "$CONTAINER_NAME:/tmp/model.onnx"
docker exec "$CONTAINER_NAME" cp "/tmp/model.onnx" "$DATA_PUMP_DIR/model.onnx"

# Enable extended VARCHAR2 (32767) support — must run before any DDL that uses it
enable_extended_string_size

generate_sql_files
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" system
run_sql_file "$RUN_DIR/sql-scripts/vector-setup.sql" system

# --- Phase 2: Start ORDS (auto-installs APEX into DB, then serves it on port $APEX_PORT) ---
if [ ! -d "$APEX_DIR" ] || [ -z "$(ls -A "$APEX_DIR" 2>/dev/null)" ]; then
    echo "Error: APEX directory $APEX_DIR is empty or missing."
    echo "Run './setup-for-adb-26ai.sh' first to prepare APEX."
    echo "Or set APEX_DIR in config.ini to the location of your APEX install files."
    exit 1
fi

mkdir -p "$RUN_DIR/ords_config" && chmod 777 "$RUN_DIR/ords_config"

ORDS_ALREADY_RUNNING=false
if check_container_state "ords"; then
    echo "Container ords is already running — reusing."
    ORDS_ALREADY_RUNNING=true
else
    echo "Starting ORDS container (installs APEX on first run — allow 30-60 minutes)..."
    docker compose -f "$RUN_DIR/docker-compose.yml" --env-file "$RUN_DIR/.env" up -d ords
fi
wait_for_ords 3600

echo "Configuring APEX workspace for $APEX_USER..."
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" system

# --- Phase 3: Configure Ollama generative AI service ---
ensure_ollama_firewall_rule
grant_sys_packages "$APEX_USER"
echo "Configuring network ACL and Ollama generative AI service..."
run_sql_file "$RUN_DIR/sql-scripts/setup-ollama-ai.sql" system

# Validate the full chain: DB → Docker network → host → Ollama → LLM response
validate_ollama_from_db || true  # don't fail the whole setup if Ollama isn't running

echo ""
echo "=== Setup complete ==="
echo "1. DB logs:    docker logs -f $CONTAINER_NAME"
echo "2. ORDS logs:  docker logs -f ords"
echo "3. NOT SECURE: for Demo and POC use only"
echo "4. APEX:       http://localhost:$APEX_PORT/ords/apex  (Workspace/User: $APEX_USER, Password: $APEX_PASSWORD)"
echo "5. EM Express: https://localhost:5500/em"
echo "6. SQLplus:    $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus system/$DEFAULT_PASSWORD@$SERVICE_NAME"
echo "7. SSH tunnel: ssh -L $APEX_PORT:localhost:$APEX_PORT -L 5500:localhost:5500 -N ubuntu@<server-ip>"
echo "8. Ollama:     $OLLAMA_BASE_URL (model: $OLLAMA_MODEL)"
echo "   Test SQL:   SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT('Hello', JSON('{\"provider\":\"ollama\",\"host\":\"$OLLAMA_BASE_URL\",\"model\":\"$OLLAMA_MODEL\"}')) FROM dual;"
