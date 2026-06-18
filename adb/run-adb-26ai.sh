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

    echo "Stopping and removing Ollama proxy container..."
    docker stop "$PROXY_CONTAINER" >/dev/null 2>&1 || true
    docker rm   "$PROXY_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$PROXY_NETWORK" >/dev/null 2>&1 || true

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
    echo "Usage: $0 [-k] [-n] [-c [-r]] | -h"
    echo "Options:"
    echo "  -k     Stop k3s inside Colima before starting Oracle (frees 6-8 GB)"
    echo "         Use when mifos-gazelle Kubernetes pods are running."
    echo "         Restore k3s later: colima ssh -- sudo systemctl start k3s"
    echo "  -n     Dry-run: show what would be done without making any changes"
    echo "  -c     Cleanup: stop and remove ADB container, prompt to remove data dir"
    echo "  -r     Also remove Docker image (requires -c; default: image is kept)"
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

    # Check whether the container has a HEALTHCHECK — the adb-free image does not define one
    # by default, so docker inspect returns a template error ("map has no entry for key Health").
    # When that happens, fall back to polling container logs for the ORDS HTTPS ready signal.
    local has_hc
    has_hc=$(docker inspect --format='{{if .Config.Healthcheck}}yes{{else}}no{{end}}' \
        "$CONTAINER_NAME" 2>/dev/null || echo "no")

    if [ "$has_hc" = "no" ]; then
        echo "  Container has no HEALTHCHECK — polling logs for ORDS HTTPS ready signal..."
        _wait_for_ords_log "$TIMEOUT"
        return
    fi

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

# Fallback readiness check for containers without a HEALTHCHECK.
# Polls docker logs until ORDS reports its HTTPS endpoint is up.
_wait_for_ords_log() {
    local timeout=$1
    local start elapsed
    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start ))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "Timeout of ${timeout}s reached waiting for ORDS HTTPS. Exiting."
            exit 1
        fi
        if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "HTTPS listening on host"; then
            echo "Container $CONTAINER_NAME: ORDS HTTPS endpoint is up."
            echo "Total time taken: $(print_elapsed_time $elapsed)"
            return 0
        fi
        echo "Waiting for ORDS HTTPS... Elapsed: $(print_elapsed_time $elapsed)"
        sleep 15
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

# Pipe SQL from stdin to sqlplus. Used for short inline statements where a temp
# file would be noisy. Inherits WALLET_DIR, ORACLE_CLIENT_DIR, INSTANT_CLIENT.
# Usage: run_sql_stdin [user]   (default: admin)  <<'SQL'  ...  SQL
run_sql_stdin() {
    local user="${1:-admin}"
    TNS_ADMIN="$WALLET_DIR" \
    LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
        "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus" -s "$user/$DEFAULT_PASSWORD@$SERVICE_NAME"
}

# Enable MAX_STRING_SIZE=EXTENDED so VARCHAR2(32767) columns are supported.
# ADB-Free typically has this enabled by default — the check will return early.
enable_extended_string_size() {
    echo "=== Checking MAX_STRING_SIZE ==="

    # Check via wallet-based external sqlplus (avoids docker exec -i stdin-EOF hang on macOS).
    # ADB-free ATP containers always have EXTENDED pre-configured; || true skips if unreachable.
    local current
    current=$(run_sql_stdin admin 2>/dev/null <<'SQLEOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TRIMOUT ON TRIMSPOOL ON
SELECT value FROM v$parameter WHERE name='max_string_size';
EXIT;
SQLEOF
    ) || true
    current=$(echo "$current" | tr -d '[:space:]')

    # tr portable uppercase; treat empty (connection failed) as EXTENDED — safe for ADB-free
    if [ "$(echo "$current" | tr '[:lower:]' '[:upper:]')" = "EXTENDED" ] || [ -z "$current" ]; then
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

    # Also generate setup-ollama-ai.sql from its template so config values
    # (APEX_USER, Ollama URL, model name) stay in sync with config.ini.
    local OLLAMA_TPL="$RUN_DIR/sql-scripts/setup-ollama-ai.sql.tpl"
    local OLLAMA_OUT="$RUN_DIR/sql-scripts/setup-ollama-ai.sql"
    if [ -f "$OLLAMA_TPL" ]; then
        local _ollama_cfg _ollama_base_url _ollama_model
        _ollama_cfg=$(ini_val LLM_OLLAMA_LOCAL 2>/dev/null || true)
        _ollama_base_url="${_ollama_cfg%%|*}"
        _ollama_model="$(echo "$_ollama_cfg" | awk -F'|' '{print $2}')"
        _ollama_base_url="${_ollama_base_url:-http://host.docker.internal:11434}"
        _ollama_model="${_ollama_model:-llama3.2:3b}"
        sed -e "s/__APEX_USER__/$APEX_USER/g" \
            -e "s/__APEX_PASSWORD__/$APEX_PASSWORD/g" \
            -e "s|__OLLAMA_BASE_URL__|$_ollama_base_url|g" \
            -e "s/__OLLAMA_MODEL__/$_ollama_model/g" \
            "$OLLAMA_TPL" > "$OLLAMA_OUT"
    fi
}

# After the Oracle DB user is created by create-users.sql, use adb-cli change-password
# to ensure the DB user password is fully initialised in ADB's credential store.
# Only called when APEX_PASSWORD differs from DEFAULT_PASSWORD (same-password change
# would fail with ORA-28007). Falls back to change-expired-password for expired accounts.
setup_apex_user_db_password() {
    if [ "$APEX_PASSWORD" = "$DEFAULT_PASSWORD" ]; then
        echo "$APEX_USER DB password matches DEFAULT_PASSWORD — skipping adb-cli change-password."
        return 0
    fi
    echo "Setting $APEX_USER DB password via adb-cli..."
    docker exec "$CONTAINER_NAME" adb-cli change-password \
        --database-name "MYATP" \
        --user  "$APEX_USER" \
        --old-password "$DEFAULT_PASSWORD" \
        --new-password "$APEX_PASSWORD" \
    || docker exec "$CONTAINER_NAME" adb-cli change-expired-password \
        --database-name "MYATP" \
        --user  "$APEX_USER" \
        --old-password "$DEFAULT_PASSWORD" \
        --new-password "$APEX_PASSWORD" \
    || echo "Note: adb-cli password change skipped — DB user password already correct or ORA-28007 reuse."
}

# Start the ADB-Free 26ai single container (ORDS and APEX are pre-installed).
run_adb() {
    echo "Starting ADB container from $DOCKER_IMAGE..."
    # ADB-Free listens on 1522 internally; 1521 maps to the standard Oracle port externally.
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
        --health-cmd "curl -sk https://localhost:8443/ords/ >/dev/null 2>&1 || exit 1" \
        --health-interval 30s \
        --health-start-period 120s \
        --health-timeout 10s \
        --health-retries 40 \
        "$DOCKER_IMAGE"
}

# ─────────────────────────────────────────────────────────────────
# Dry-run plan — print what would happen for the given flags, then exit.
# Reads docker state but makes no changes.
# ─────────────────────────────────────────────────────────────────
show_dry_run_plan() {
    local flag_str=""
    [ "$STOP_K3S"       = "true" ] && flag_str="${flag_str} -k"
    [ "$DO_CLEANUP"     = "true" ] && flag_str="${flag_str} -c"
    [ "$REMOVE_IMAGES"  = "true" ] && flag_str="${flag_str} -r"
    flag_str="${flag_str:- (no flags — normal startup)}"

    echo ""
    echo "=== DRY-RUN: what run-adb-26ai.sh${flag_str} would do ==="
    echo ""

    # ── Current state (read-only; errors ignored if docker not running) ──
    local container_state="not found"
    local cid
    cid=$(docker ps -aq -f "name=^${CONTAINER_NAME}$" 2>/dev/null || true)
    if [ -n "$cid" ]; then
        container_state=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    fi

    local image_cached="not cached"
    docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1 && image_cached="cached locally"

    local data_dir_state="does not exist"
    if [ -d "$HOME/db_data_dir" ]; then
        data_dir_state="exists ($(du -sh "$HOME/db_data_dir" 2>/dev/null | cut -f1))"
    fi

    local model_state="not downloaded"
    [ -f "$MODEL_PATH" ] && model_state="exists ($(du -sh "$MODEL_PATH" 2>/dev/null | cut -f1))"

    local wallet_state="not present"
    [ -d "$HOME/auth/tls_wallet" ] && wallet_state="exists"

    local client_state="NOT FOUND — run setup first"
    [ -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ] && client_state="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"

    local k3s_state="n/a (Linux)"
    if [ "$PLATFORM" = "darwin" ]; then
        if k3s_is_running_mac 2>/dev/null; then
            local _pc _stop_note=""
            _pc=$(k3s_app_pod_count_mac 2>/dev/null || echo "?")
            [ "$STOP_K3S" = "true" ] && _stop_note="  → will be stopped (-k)" || true
            k3s_state="running  ($_pc app pods)$_stop_note"
        else
            k3s_state="stopped"
        fi
    fi

    echo "Current state:"
    printf "  %-30s %s\n" "Container '$CONTAINER_NAME':"  "$container_state"
    printf "  %-30s %s\n" "Docker image:"                 "$DOCKER_IMAGE  ($image_cached)"
    printf "  %-30s %s\n" "Data dir ~/db_data_dir:"       "$data_dir_state"
    printf "  %-30s %s\n" "ONNX model ~/model.onnx:"      "$model_state"
    printf "  %-30s %s\n" "TLS wallet ~/auth/tls_wallet:" "$wallet_state"
    printf "  %-30s %s\n" "Instant Client:"               "$client_state"
    printf "  %-30s %s\n" "k3s (mifos-gazelle):"          "$k3s_state"
    echo ""

    if [ "$DO_CLEANUP" = "true" ]; then
        # ── Cleanup plan ────────────────────────────────────────────────
        echo "Steps (-c):"
        if [ "$container_state" = "not found" ]; then
            echo "  docker stop $CONTAINER_NAME   ← nothing to stop (not found)"
            echo "  docker rm   $CONTAINER_NAME   ← nothing to remove (not found)"
        else
            echo "  docker stop $CONTAINER_NAME   ← current state: $container_state"
            echo "  docker rm   $CONTAINER_NAME"
        fi
        echo "  [interactive prompt] Remove ~/db_data_dir? (y → sudo rm -rf ~/db_data_dir)"
        if [ "$REMOVE_IMAGES" = "true" ]; then
            if docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1; then
                echo "  docker rmi $DOCKER_IMAGE"
            else
                echo "  docker rmi $DOCKER_IMAGE   ← image not cached, nothing to remove"
            fi
        else
            echo "  Image kept  (re-run with -c -r to also remove the image)"
        fi
    else
        # ── Normal startup plan ─────────────────────────────────────────
        echo "Steps:"
        if [ "$STOP_K3S" = "true" ]; then
            echo "  colima ssh -- sudo systemctl stop k3s  (-k: pause k3s to free 6-8 GB)"
        fi
        if [ -d "$HOME/db_data_dir" ]; then
            echo "  mkdir -p ~/db_data_dir             ← already exists, skip"
        else
            echo "  mkdir -p ~/db_data_dir  chmod 777"
        fi

        if [ "$container_state" = "running" ]; then
            echo "  Container already running — skip docker run, reuse existing"
        else
            if docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1; then
                echo "  Image already cached — skip pull"
            else
                echo "  docker pull $DOCKER_IMAGE"
                echo "              (15–20 GB first pull — may take a while)"
            fi
            echo "  docker run -d \\"
            echo "      -p 1521:1522 -p 1522:1522 -p 8443:8443 -p 27017:27017 \\"
            echo "      -e WORKLOAD_TYPE=ATP \\"
            echo "      -e WALLET_PASSWORD='<DEFAULT_PASSWORD>' \\"
            echo "      -e ADMIN_PASSWORD='<DEFAULT_PASSWORD>' \\"
            echo "      --hostname $HOSTNAME \\"
            echo "      --cap-add SYS_ADMIN \\"
            echo "      --device /dev/fuse \\"
            echo "      --volume ~/db_data_dir:/u01/data \\"
            echo "      --name $CONTAINER_NAME \\"
            echo "      $DOCKER_IMAGE"
            echo "  wait for container healthy (timeout 1800s)"
            echo "  sleep 30  (stabilisation pause)"
        fi

        if [ -f "$MODEL_PATH" ]; then
            echo "  ONNX model already cached — skip download"
        else
            echo "  curl -fL -C - -o ~/model.onnx \\"
            echo "      $ONNX_MODEL_URL"
        fi

        echo "  docker cp $CONTAINER_NAME:/u01/app/oracle/wallets/tls_wallet/ ~/auth/"
        echo "  cp ~/model.onnx ~/db_data_dir/model.onnx  (Oracle sees /u01/data/model.onnx)"
        echo "  sqlplus admin → CREATE OR REPLACE DIRECTORY ONNX_STAGING AS '/u01/data';"
        echo "  check MAX_STRING_SIZE — enable EXTENDED if not already set (usually a no-op)"
        echo "  generate create-users.sql + setup-ollama-ai.sql from templates (APEX_USER=$APEX_USER)"
        echo "  sqlplus admin/<pw>@$SERVICE_NAME @$RUN_DIR/sql-scripts/create-users.sql"
        echo "  sqlplus admin/<pw>@$SERVICE_NAME @$RUN_DIR/sql-scripts/setup-ollama-ai.sql  (non-fatal)"
        echo "  (ONNX model loading is app-level — use load-apex-app.sh -v <vector-setup.sql>)"
    fi

    echo ""
    echo "=== No changes made. Run without -n to execute. ==="
    exit 0
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
        echo "Note: Oracle image not cached locally — will pull $DOCKER_IMAGE on first run."
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

# Start an nginx Docker container that wraps Ollama's HTTP in HTTPS.
# Required because ADB-Free enforces REQUIRE_OUT_HTTPS=Y (non-settable) — all
# outbound APEX web service calls must use HTTPS.
start_ollama_proxy() {
    echo "=== Setting up Ollama HTTPS proxy ==="

    # Generate a 10-year self-signed cert once; no rotation needed in dev/on-prem.
    if [ ! -f "$PROXY_CERT" ] || [ ! -f "$PROXY_KEY" ]; then
        echo "  Generating self-signed proxy certificate..."
        openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 \
            -keyout "$PROXY_KEY" -out "$PROXY_CERT" -nodes \
            -subj "/CN=ollama-proxy/O=oracle-local-dev" \
            -addext "subjectAltName=DNS:ollama-proxy,DNS:localhost,IP:127.0.0.1"
        echo "  Certificate saved to $PROXY_CERT"
    fi

    # Create shared network so Oracle can reach the proxy by container name (DNS:ollama-proxy).
    # Container-name DNS only works on named networks, not the default bridge.
    docker network create "$PROXY_NETWORK" 2>/dev/null || true

    # check_container_state: returns 0 = running (reuse), 1 = missing/stale (recreate).
    if check_container_state "$PROXY_CONTAINER"; then
        echo "  Proxy container already running — ensuring it is on $PROXY_NETWORK..."
        docker network connect "$PROXY_NETWORK" "$PROXY_CONTAINER" 2>/dev/null || true
        return 0
    fi
    docker run -d \
        --name "$PROXY_CONTAINER" \
        --network "$PROXY_NETWORK" \
        -p "${PROXY_PORT}:443" \
        -v "$RUN_DIR/ollama-proxy/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$PROXY_CERT:/etc/nginx/certs/proxy.crt:ro" \
        -v "$PROXY_KEY:/etc/nginx/certs/proxy.key:ro" \
        --add-host "host.docker.internal:host-gateway" \
        nginx:alpine
    echo "  Proxy started: https://ollama-proxy:443 → http://host.docker.internal:11434"
    # Also connect ADB container to the same network so it can resolve 'ollama-proxy' by name.
    docker network connect "$PROXY_NETWORK" "$CONTAINER_NAME" 2>/dev/null || true
    echo "  $CONTAINER_NAME connected to $PROXY_NETWORK"
}

# Add the proxy cert to Oracle's ssl_wallet (the wallet ADB-Free always uses for
# UTL_HTTP outbound SSL — UTL_HTTP.set_wallet() is silently ignored in ADB-Free).
#
# Approach: export all existing CA certs from ssl_wallet (no password needed for
# read), build a new wallet with -with_trust_flags containing all original CAs +
# our cert (both with SERVER_AUTH), then replace only the cwallet.sso (the
# auto-login file Oracle reads at runtime). ewallet.p12 is left untouched.
# Also add to OS trust store so tools like curl inside the container also trust it.
#
# Idempotent: orapki wallet create -auto_login always regenerates cwallet.sso;
# running again after a cert change simply rebuilds and replaces it.
# Must run after the ADB container is healthy.
trust_proxy_cert() {
    echo "=== Trusting proxy cert in Oracle ssl_wallet (ADB-Free UTL_HTTP trust store) ==="

    # 1. Add cert to OS trust store (for curl/openssl inside container) — idempotent.
    docker cp "$PROXY_CERT" "${CONTAINER_NAME}:/etc/pki/ca-trust/source/anchors/ollama-proxy.crt"
    docker cp "$PROXY_CERT" "${CONTAINER_NAME}:/tmp/proxy.crt"
    docker exec -u root "$CONTAINER_NAME" update-ca-trust
    echo "  Cert added to Oracle Linux OS trust store."

    # 2. Rebuild ssl_wallet cwallet.sso to include our proxy cert.
    #    ADB-Free's ssl_wallet is the only trust store UTL_HTTP uses; set_wallet() is a no-op.
    docker exec -i -u oracle "$CONTAINER_NAME" /bin/bash << 'TRUST_SHELL'
# Auto-detect Java home (path varies by Oracle image version)
export JAVA_HOME=$(readlink -f /etc/alternatives/java 2>/dev/null | sed 's|/bin/java||')
[ -z "$JAVA_HOME" ] && export JAVA_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d -name "jdk*" 2>/dev/null | head -1)
echo "  Using JAVA_HOME=$JAVA_HOME"
ORAPKI=/u01/app/oracle/product/23.0.0.0/dbhome_1/bin/orapki
SSL=/u01/app/oracle/wallets/ssl_wallet
NEW=/tmp/new_ssl_wallet
CERTS=/tmp/ssl_certs
TMPWD="TempWallet_$(openssl rand -hex 4)"

echo "  Exporting existing CA certs from ssl_wallet..."
mkdir -p "$CERTS"
rm -rf "$CERTS"/* "$NEW"

# Get all subject DNs and export each cert (no password needed for auto-login wallet).
# Skip our proxy cert DN — it will be added explicitly below so there's no duplicate.
$ORAPKI wallet display -wallet "$SSL" 2>&1 | grep "Subject:" | sed "s/Subject://" | sed "s/^ *//" \
    | grep -v "CN=ollama-proxy" > /tmp/ssl_dns.txt
i=0
while IFS= read -r dn; do
    i=$((i+1))
    $ORAPKI wallet export -wallet "$SSL" -dn "$dn" -cert "$CERTS/cert_$(printf "%03d" $i).crt" 2>/dev/null
done < /tmp/ssl_dns.txt
echo "  Exported $(ls "$CERTS" | wc -l) certs from ssl_wallet."

# Create new wallet with trust-flag support
$ORAPKI wallet create -wallet "$NEW" -auto_login -with_trust_flags -pwd "$TMPWD" 2>/dev/null

# Add all original certs (with SERVER_AUTH for CA certs; without for end-entity certs)
ok=0; skip=0
for crt in "$CERTS"/cert_*.crt; do
    result=$($ORAPKI wallet add -wallet "$NEW" -trusted_cert -trust_flags SERVER_AUTH -cert "$crt" -pwd "$TMPWD" 2>&1 | tail -1)
    if echo "$result" | grep -q "end entity"; then
        # End-entity cert — add without trust flag
        $ORAPKI wallet add -wallet "$NEW" -trusted_cert -cert "$crt" -pwd "$TMPWD" 2>/dev/null
        skip=$((skip+1))
    else
        ok=$((ok+1))
    fi
done
echo "  Re-added $ok CA certs with SERVER_AUTH, $skip end-entity certs."

# Add our proxy cert with SERVER_AUTH
$ORAPKI wallet add -wallet "$NEW" -trusted_cert -trust_flags SERVER_AUTH -cert /tmp/proxy.crt -pwd "$TMPWD" 2>&1 | tail -1

# Backup original and replace cwallet.sso (Oracle reads this at runtime; ewallet.p12 untouched)
cp "$SSL/cwallet.sso" "$SSL/cwallet.sso.bak" 2>/dev/null || true
cp "$NEW/cwallet.sso" "$SSL/cwallet.sso"
echo "  ssl_wallet cwallet.sso rebuilt with proxy cert included."
TRUST_SHELL

    # 3. Drop any stale logon trigger from prior attempts (no longer needed)
    run_sql_stdin admin << 'TRUST_EOF'
SET SERVEROUTPUT ON
BEGIN
  FOR t IN (SELECT trigger_name FROM all_triggers
            WHERE owner = 'ADMIN' AND trigger_name LIKE '%SSL_WALLET%') LOOP
    EXECUTE IMMEDIATE 'DROP TRIGGER admin.' || t.trigger_name;
    DBMS_OUTPUT.PUT_LINE('Dropped stale trigger: ADMIN.' || t.trigger_name);
  END LOOP;
END;
/
EXIT;
TRUST_EOF
    echo "  Oracle proxy cert trusted — UTL_HTTP outbound HTTPS to ollama-proxy will succeed."
}

####### main #######
PLATFORM=""
ARCH=""
WALLET_DIR=""
TNS_ADMIN=""
ORACLE_CLIENT_DIR="$HOME/oraclient"
MODEL_PATH="$HOME/model.onnx"
REMOVE_IMAGES=false
DRY_RUN=false
DO_CLEANUP=false
STOP_K3S=false
RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROXY_CERT="$RUN_DIR/ollama-proxy.crt"
PROXY_KEY="$RUN_DIR/ollama-proxy.key"
PROXY_CONTAINER="ollama-proxy"
PROXY_PORT=11435
PROXY_NETWORK="oracle-ai-net"

detect_platform

# Source common utilities (ini_val, avail_kb_for_dir, colour helpers).
# CONFIG_FILE not yet set — common.sh functions that use it are called later.
# shellcheck source=common.sh
source "$RUN_DIR/common.sh"

# Source platform-specific helpers.
if [ "$PLATFORM" = "darwin" ]; then
    # Read CONTAINER_RUNTIME early (before full read_config) so set_docker_host_mac gets the right value.
    CONTAINER_RUNTIME=$(grep -m1 "^CONTAINER_RUNTIME=" "$RUN_DIR/config.ini" 2>/dev/null | cut -d'=' -f2- | tr -d ' \n\r')
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-auto}"
    # shellcheck source=mac_helpers.sh
    source "$RUN_DIR/mac_helpers.sh"
    set_docker_host_mac
else
    # shellcheck source=linux_helpers.sh
    source "$RUN_DIR/linux_helpers.sh"
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
DRY_RUN=false
while getopts "hcknr" opt; do
    case ${opt} in
        h ) usage ;;
        c ) DO_CLEANUP=true ;;
        k ) STOP_K3S=true ;;
        r ) REMOVE_IMAGES=true ;;
        n ) DRY_RUN=true ;;
        \? ) usage ;;
    esac
done

if [ "$REMOVE_IMAGES" = "true" ] && [ "$DO_CLEANUP" = "false" ]; then
    echo "ERROR: -r (remove image) requires -c (cleanup). Use: $0 -c -r"
    exit 1
fi

if [ "$DRY_RUN" = "true" ]; then
    show_dry_run_plan
fi

if [ "$DO_CLEANUP" = "true" ]; then
    cleanup
fi

# Stop k3s before starting Oracle if requested or if it's running with app pods.
if [ "$PLATFORM" = "darwin" ]; then
    if [ "$STOP_K3S" = "true" ]; then
        stop_k3s_mac
    elif k3s_is_running_mac 2>/dev/null; then
        _pod_count=$(k3s_app_pod_count_mac 2>/dev/null || echo 0)
        if [ "${_pod_count:-0}" -gt 0 ]; then
            echo ""
            echo "WARNING: k3s is running with $_pod_count application pod(s) in the Colima VM."
            echo "         These compete with Oracle ADB for memory (6-8 GB)."
            echo "         Run with -k to stop k3s automatically, or stop it manually:"
            echo "           colima ssh -- sudo systemctl stop k3s"
            echo ""
        fi
        unset _pod_count
    fi
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

start_ollama_proxy
trust_proxy_cert

# Stage ONNX model where the Oracle DB process can read it.
# ADB-Free's Oracle process uses an internal DBFS namespace — Docker volume mounts at
# /u01/data are not directly visible to the Oracle process. After creating the DIRECTORY
# object pointing to '/u01/data', we query dba_directories to get the resolved DBFS path
# (e.g. /u01/dbfs/<GUID>/data/u01/data) and copy the model file there.
echo "Creating Oracle DIRECTORY 'ONNX_STAGING' → /u01/data ..."
run_sql_stdin admin <<'SQLEOF'
SET FEEDBACK OFF
CREATE OR REPLACE DIRECTORY ONNX_STAGING AS '/u01/data';
EXIT;
SQLEOF
echo "ONNX_STAGING directory created."

echo "Staging ONNX model to Oracle-visible DBFS path..."
_dbfs_path=$(run_sql_stdin admin <<'SQLEOF'
SET FEEDBACK OFF HEADING OFF PAGESIZE 0
SELECT directory_path FROM dba_directories WHERE directory_name = 'ONNX_STAGING';
EXIT;
SQLEOF
)
_dbfs_path=$(echo "$_dbfs_path" | tr -d ' \r\n')
if [ -n "$_dbfs_path" ]; then
    docker exec -u root "$CONTAINER_NAME" mkdir -p "$_dbfs_path"
    docker cp "$MODEL_PATH" "${CONTAINER_NAME}:${_dbfs_path}/model.onnx"
    docker exec -u root "$CONTAINER_NAME" chmod 644 "${_dbfs_path}/model.onnx"
    echo "  ONNX model copied to DBFS path: ${_dbfs_path}/model.onnx"
else
    echo "  WARNING: Could not determine DBFS path — ONNX model load may fail (ORA-22288)."
fi

# Enable extended VARCHAR2(32767) support — ADB-Free typically has this already; will be a no-op.
enable_extended_string_size

generate_sql_files
run_sql_file "$RUN_DIR/sql-scripts/create-users.sql" admin
setup_apex_user_db_password

echo "Configuring LLM integration..."
run_sql_file "$RUN_DIR/sql-scripts/setup-ollama-ai.sql" admin || true

echo ""
echo "=== Setup complete ==="
echo "1. DB logs:    docker logs -f $CONTAINER_NAME"
echo "2. NOT SECURE: for Demo and POC use only"
echo "3. APEX:       https://localhost:$APEX_PORT/ords/apex  (accept self-signed cert on first visit)"
echo "   APEX admin: Workspace=internal  User=ADMIN        Password=$DEFAULT_PASSWORD"
echo "   APEX user:  Workspace=$APEX_USER  User=$APEX_USER  Password=$APEX_PASSWORD"
echo "4. sqlplus:    TNS_ADMIN=$HOME/auth/tls_wallet $ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus admin/$DEFAULT_PASSWORD@$SERVICE_NAME"
echo "5. SSH tunnel: ssh -L $APEX_PORT:localhost:$APEX_PORT -N ubuntu@<server-ip>"
_ollama_cfg=$(ini_val LLM_OLLAMA_LOCAL 2>/dev/null || true)
if [ -n "${_ollama_cfg:-}" ]; then
    OLLAMA_BASE_URL="${_ollama_cfg%%|*}"
    OLLAMA_MODEL="$(echo "$_ollama_cfg" | awk -F'|' '{print $2}')"
    echo "6. Ollama:     $OLLAMA_BASE_URL (model: $OLLAMA_MODEL)"
    echo "   Test SQL:   SELECT DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT('Hello', JSON('{\"provider\":\"ollama\",\"host\":\"$OLLAMA_BASE_URL\",\"model\":\"$OLLAMA_MODEL\"}')) FROM dual;"
fi
