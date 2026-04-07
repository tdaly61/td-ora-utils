#!/usr/bin/env bash

# Function to clean up Docker resources
# Respects $REMOVE_IMAGES — set via -r flag (default: false)
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
    read choice
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


# Function to check if Docker containers with the expected names already exist
check_existing_container() {
    if [ "$(docker ps -aq -f name=^${CONTAINER_NAME}$)" ]; then
        echo "Container $CONTAINER_NAME already exists. Run ./run-adb-26ai.sh -c to clean up."
        exit 1
    fi
    if [ "$(docker ps -aq -f name=^ords$)" ]; then
        echo "Container ords already exists. Run ./run-adb-26ai.sh -c to clean up."
        exit 1
    fi
}

# Function to display usage
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

# Generate .env file for docker compose from config.ini values
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

# Function to print the elapsed time in a human-readable format
print_elapsed_time() {
    local SECONDS=$1
    local HOURS=$((SECONDS / 3600))
    local MINUTES=$(( (SECONDS % 3600) / 60 ))
    local SECONDS=$((SECONDS % 60))
    printf "%02d:%02d:%02d\n" $HOURS $MINUTES $SECONDS
}

# Function to wait for the DB container to be healthy
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

        STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME")
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

# Function to patch ORDS pool.xml after APEX install completes.
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
#   Both sides now agree on credentials every time.
patch_ords_pool_config() {
    local POOL_XML="$RUN_DIR/ords_config/databases/default/pool.xml"

    echo "Patching ORDS pool.xml (ORDS 25.x does not persist hostname or credentials)..."

    # Step 1: Reset ORDS_PUBLIC_USER password in the DB to DEFAULT_PASSWORD so
    # it matches what we will put in pool.xml.
    echo "  Resetting ORDS_PUBLIC_USER password in DB..."
    docker exec "$CONTAINER_NAME" bash -c \
        "echo \"ALTER USER ORDS_PUBLIC_USER IDENTIFIED BY \\\"$DEFAULT_PASSWORD\\\";\" | \
         sqlplus -s sys/$DEFAULT_PASSWORD@localhost:1521/$SERVICE_NAME as sysdba" \
        2>/dev/null | grep -v '^$' || echo "  Warning: could not reset ORDS_PUBLIC_USER password."

    # Step 2: Write pool.xml with all required entries.
    # pool.xml may be owned by oracle (uid 54321) inside the container — remove it
    # via docker exec so we can create a fresh one (ords_config dir is chmod 777).
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

# Function to wait for ORDS/APEX HTTP endpoint to respond
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
        # HTTP 571: ORDS running but DB connection failed (pool.xml missing host).
        # Patch once and restart.
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

# Function to download the ONNX model if not already downloaded
get_model() {
    if [ ! -f "$MODEL_PATH" ]; then
        echo "Downloading ONNX model from $ONNX_MODEL_URL... to $MODEL_PATH"
        curl -o "$MODEL_PATH" "$ONNX_MODEL_URL"
        if [ $? -ne 0 ]; then
            echo "Failed to download the ONNX model. Exiting."
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
    mkdir -p $TNS_DIR

    # Create tnsnames.ora for Oracle Database Free local connections
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

# Function to run a SQL file
run_sql_file() {
    local sql_file="$1"
    local user="$2"

    if [ ! -f "$sql_file" ]; then
        echo "SQL file $sql_file does not exist. Skipping."
        return 1
    fi
    echo "Running SQL file $sql_file..."
    LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus" -s "$user/$DEFAULT_PASSWORD@$SERVICE_NAME" "@$sql_file"
    if [ $? -ne 0 ]; then
        echo "Failed to execute SQL file $sql_file."
        return 1
    fi
    echo "SQL file $sql_file executed successfully."
}

# Function to read configuration from config.ini
read_config() {
    CONFIG_FILE="$RUN_DIR/config.ini"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration file config.ini not found in $RUN_DIR. Exiting."
        exit 1
    fi
    SQLPLUS_URL=$(awk -F "=" '/^SQLPLUS_URL/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    INSTANT_CLIENT=$(awk -F "=" '/^INSTANT_CLIENT/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    HOSTNAME=$(awk -F "=" '/^HOSTNAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    DEFAULT_PASSWORD=$(awk -F "=" '/^DEFAULT_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' '  | tr -d '\n' | tr -d '\r')
    CONTAINER_NAME=$(awk -F "=" '/^CONTAINER_NAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    DOCKER_IMAGE=$(awk -F "=" '/^DOCKER_IMAGE/ {print $2}' "$CONFIG_FILE" | tr -d ' '  )
    ONNX_MODEL_URL=$(awk -F "=" '/^ONNX_MODEL_URL/ {print $2}' "$CONFIG_FILE" | tr -d ' '  )
    ORACLE_REGISTRY_USER=$(awk -F "=" '/^ORACLE_REGISTRY_USER/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    ORACLE_REGISTRY_PASSWORD=$(awk -F "=" '/^ORACLE_REGISTRY_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    SERVICE_NAME=$(awk -F "=" '/^SERVICE_NAME/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    APEX_PORT=$(awk -F "=" '/^APEX_PORT/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    APEX_PORT=${APEX_PORT:-8080}
    APEX_DIR=$(awk -F "=" '/^APEX_DIR/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    APEX_DIR=${APEX_DIR:-$HOME/apex}

    APEX_USER=$(awk -F "=" '/^APEX_USER/ {print $2}' "$CONFIG_FILE" | tr -d ' ')
    APEX_USER=${APEX_USER:-TRACKER1}
    APEX_PASSWORD=$(awk -F "=" '/^APEX_PASSWORD/ {print $2}' "$CONFIG_FILE" | tr -d ' ' | tr -d '\n' | tr -d '\r')
    APEX_PASSWORD=${APEX_PASSWORD:-$DEFAULT_PASSWORD}

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

# Pre-flight checks — catch common environment problems before starting long operations
preflight_check() {
    local errors=0

    echo "--- Pre-flight checks ---"

    # Docker must be installed and running
    if ! command -v docker &>/dev/null; then
        echo "ERROR: Docker is not installed. Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    elif ! docker info &>/dev/null 2>&1; then
        if sudo systemctl is-active --quiet docker 2>/dev/null; then
            echo "ERROR: Docker is running but not accessible. Log out and back in, or re-run with sudo."
        else
            echo "ERROR: Docker is not running. Run: sudo systemctl start docker"
        fi
        errors=$((errors + 1))
    fi

    # Docker Compose plugin
    if ! docker compose version &>/dev/null 2>&1; then
        echo "ERROR: Docker Compose plugin not found. Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    fi

    # Oracle Instant Client (sqlplus)
    if [ ! -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
        echo "ERROR: Instant Client not found at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
        echo "       Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    fi

    # APEX directory must be populated (ORDS needs it on first run)
    local effective_apex_dir="${APEX_DIR:-$HOME/apex}"
    if [ ! -d "$effective_apex_dir" ] || [ -z "$(ls -A "$effective_apex_dir" 2>/dev/null)" ]; then
        echo "ERROR: APEX directory missing or empty: $effective_apex_dir"
        echo "       Run: sudo ./setup-for-adb-26ai.sh"
        errors=$((errors + 1))
    fi

    # Oracle Container Registry — images are publicly pullable (no login required).
    # Login is only needed if pulls start failing (e.g. rate limits or policy change).
    if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null || \
       ! docker image inspect container-registry.oracle.com/database/ords:latest &>/dev/null; then
        echo "Note: Oracle images not cached locally — will pull from container-registry.oracle.com (no login required)."
    fi

    # Disk space: Oracle Free container needs ~15 GB for oradata
    local avail_kb
    avail_kb=$(df "$HOME" --output=avail 2>/dev/null | tail -1)
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 15728640 ]; then  # 15 GB in KB
        echo "WARNING: Less than 15 GB free in $HOME — Oracle Database container may run out of space."
    fi

    # docker-compose.yml must be present
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

# Generate SQL files from templates, substituting config values
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


####### main code #######
WALLET_DIR=""
TNS_ADMIN=""
ORACLE_CLIENT_DIR="$HOME/oraclient"
MODEL_PATH="$HOME/model.onnx"
REMOVE_IMAGES=false
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # the directory that this script is in

# If docker isn't accessible, try to apply the docker group without requiring a logout.
# We check /etc/group (via id -nG <username>) rather than the current session's groups,
# because this session may predate the docker group add done by setup-for-adb-26ai.sh.
if ! docker info &>/dev/null 2>&1; then
    _current_user="${SUDO_USER:-$USER}"
    if id -nG "$_current_user" 2>/dev/null | grep -qw docker; then
        echo "Docker group not active in this session — re-launching in docker group context..."
        exec sg docker -c "bash $(printf '%q ' "$0" "$@")"
    fi
    unset _current_user
    # docker isn't installed/running — preflight_check will report this clearly
fi

# sg disconnects stdin from the TTY. Reconnect so interactive prompts (e.g. cleanup read)
# work correctly in the re-exec'd process. Suppress error if no controlling TTY (non-interactive).
[ ! -t 0 ] && exec < /dev/tty 2>/dev/null || true

# Read configuration
read_config

# Parse arguments — collect all flags before acting
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
check_existing_container
create_db_data_dir
generate_env_file

# Pull images from Oracle Container Registry.
# The database/free and database/ords images are publicly accessible — no login required.
# If already cached locally the pull will just confirm the digest; if the registry is
# unreachable the cached image is used and the script continues.
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

echo "Starting Oracle Database container..."
docker compose -f "$RUN_DIR/docker-compose.yml" --env-file "$RUN_DIR/.env" up -d oracle-db
wait_for_container_healthy 1800
get_model

sleep 30

configure_sql_access
export TNS_ADMIN="$WALLET_DIR"
echo "TNS_ADMIN is $TNS_ADMIN"

# Discover DATA_PUMP_DIR path inside the container via SQL
DATA_PUMP_DIR=$(docker exec $CONTAINER_NAME bash -c \
    "echo \"SELECT directory_path FROM dba_directories WHERE directory_name='DATA_PUMP_DIR';\" | \
     sqlplus -s sys/$DEFAULT_PASSWORD@localhost:1521/$SERVICE_NAME as sysdba 2>/dev/null" \
    | grep -E '^/' | head -1 | tr -d '[:space:]')
if [ -z "$DATA_PUMP_DIR" ]; then
    # fallback to known default path in database/free container
    DATA_PUMP_DIR="/opt/oracle/admin/FREE/dpdump"
    echo "Warning: could not query DATA_PUMP_DIR, using default: $DATA_PUMP_DIR"
fi
echo "DATA_PUMP_DIR is $DATA_PUMP_DIR"
docker exec $CONTAINER_NAME ls -l $DATA_PUMP_DIR
echo "===="

# Copy ONNX model into the container
docker cp "$MODEL_PATH" "$CONTAINER_NAME:/tmp/model.onnx"
docker exec $CONTAINER_NAME cp "/tmp/model.onnx" "$DATA_PUMP_DIR/model.onnx"

# Generate SQL files from templates
generate_sql_files

# Run DB setup SQL (APEX_USER + ONNX model load)
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" system
run_sql_file "$RUN_DIR/sql-scripts/vector-setup.sql" system

# --- Phase 2: Start ORDS (auto-installs APEX into DB, then serves it on port $APEX_PORT) ---
if [ ! -d "$APEX_DIR" ] || [ -z "$(ls -A "$APEX_DIR" 2>/dev/null)" ]; then
    echo "Error: APEX directory $APEX_DIR is empty or missing."
    echo "Run 'sudo ./setup-for-adb-26ai.sh' first to prepare APEX."
    echo "Or set APEX_DIR in config.ini to the location of your APEX install files."
    exit 1
fi

# Ensure ords_config directory exists (ORDS writes its config here on first run).
# Do NOT pre-seed pool.xml — ORDS 25.x will fail to install if pool.xml exists
# but has no wallet/credentials. pool.xml is patched automatically after APEX
# install completes if ORDS returns HTTP 571 (see patch_ords_pool_config).
mkdir -p "$RUN_DIR/ords_config" && chmod 777 "$RUN_DIR/ords_config"

echo "Starting ORDS container (installs APEX on first run — allow 30-60 minutes)..."
docker compose -f "$RUN_DIR/docker-compose.yml" --env-file "$RUN_DIR/.env" up -d ords
wait_for_ords 3600

# Re-run user setup now that APEX is installed — creates APEX workspace for TRACKER1
echo "Configuring APEX workspace for TRACKER1..."
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" system

echo ""
echo "=== Setup complete ==="
echo "1. DB logs:    docker logs -f $CONTAINER_NAME"
echo "2. ORDS logs:  docker logs -f ords"
echo "3. NOT SECURE: for Demo and POC use only"
echo "4. APEX:       http://localhost:$APEX_PORT/ords/apex  (Workspace/User: $APEX_USER, Password: $APEX_PASSWORD)"
echo "5. EM Express: https://localhost:5500/em"
echo "6. SQLplus:    $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus system/$DEFAULT_PASSWORD@$SERVICE_NAME"
echo "7. SSH tunnel: ssh -L $APEX_PORT:localhost:$APEX_PORT -L 5500:localhost:5500 -N ubuntu@<server-ip>"
