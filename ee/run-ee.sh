#!/usr/bin/env bash
# run-ee.sh — main orchestrator for the ee/ POC stack.
#
# Usage:
#   ./run-ee.sh          Bring the stack up (compose up, install APEX/ORDS, wait ready)
#   ./run-ee.sh -c        Clean: docker compose down + wipe DB/ORDS state
#                          (APEX_INSTALL_DIR/ORDS_INSTALL_DIR are left alone — not stateful)
#   ./run-ee.sh -c -r     Clean, and also remove the pulled Docker images
#   ./run-ee.sh -h        Show this help
#
# Non-interactive by design (no prompts) so it can be driven by
# test/full-cycle-test.sh unattended.

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

CLEAN=0
REMOVE_IMAGES=0
while getopts ":crh" opt; do
    case $opt in
        c) CLEAN=1 ;;
        r) REMOVE_IMAGES=1 ;;
        h) grep '^#' "$0" | sed 's/^# \{0,1\}//; /^!/d'; exit 0 ;;
        \?) echo "ERROR: Unknown option -$OPTARG"; exit 1 ;;
    esac
done

cd "$EE_DIR"

if [ "$CLEAN" -eq 1 ]; then
    hdr "Cleaning ee/ stack"
    docker compose down --remove-orphans || true

    DB_DATA_DIR="$(resolve_ee_path DB_DATA_DIR ./oradata)"
    ORDS_CONFIG_DIR="$(resolve_ee_path ORDS_CONFIG_DIR ./ords_config)"

    for d in "$DB_DATA_DIR" "$ORDS_CONFIG_DIR"; do
        if [ -d "$d" ]; then
            # The DB container creates its own files/dirs as uid 54321
            # (oracle) with restrictive permissions — a plain host-user `rm
            # -rf` can hit "Permission denied" on the directories it made
            # even though the top-level dir itself is chmod 777. Delete via
            # a throwaway root container instead, so cleanup is reliable
            # regardless of what perms the DB left behind.
            docker run --rm -v "$d:/target" alpine sh -c 'rm -rf /target/* /target/.[!.]* 2>/dev/null; true'
            ok "Wiped $d"
        fi
    done

    if [ "$REMOVE_IMAGES" -eq 1 ]; then
        DOCKER_IMAGE="$(ini_val DOCKER_IMAGE)"
        ORDS_JAVA_IMAGE="$(ini_val ORDS_JAVA_IMAGE)"
        [ -n "$DOCKER_IMAGE" ] && docker rmi "$DOCKER_IMAGE" 2>/dev/null || true
        [ -n "$ORDS_JAVA_IMAGE" ] && docker rmi "$ORDS_JAVA_IMAGE" 2>/dev/null || true
        ok "Removed pulled images"
    fi

    ok "Clean complete."
    exit 0
fi

# ── Bring the stack up ────────────────────────────────────────────────────
ORACLE_PWD="$(ini_val ORACLE_PWD)"
ORACLE_PDB="$(ini_val ORACLE_PDB)"; ORACLE_PDB="${ORACLE_PDB:-FREEPDB1}"
CONTAINER_NAME="$(ini_val CONTAINER_NAME)"; CONTAINER_NAME="${CONTAINER_NAME:-caseweave-ee-db}"
ORDS_CONTAINER_NAME="$(ini_val ORDS_CONTAINER_NAME)"; ORDS_CONTAINER_NAME="${ORDS_CONTAINER_NAME:-caseweave-ee-ords}"
APEX_PORT="$(ini_val APEX_PORT)"; APEX_PORT="${APEX_PORT:-8080}"
DB_HOST_PORT="$(ini_val DB_HOST_PORT)"; DB_HOST_PORT="${DB_HOST_PORT:-1523}"
DB_HEALTHY_TIMEOUT="$(ini_val DB_HEALTHY_TIMEOUT)"; DB_HEALTHY_TIMEOUT="${DB_HEALTHY_TIMEOUT:-900}"
ORDS_HEALTHY_TIMEOUT="$(ini_val ORDS_HEALTHY_TIMEOUT)"; ORDS_HEALTHY_TIMEOUT="${ORDS_HEALTHY_TIMEOUT:-600}"
ADMIN_COMPAT_PASSWORD="$(ini_val ADMIN_COMPAT_PASSWORD)"
[ -z "$ADMIN_COMPAT_PASSWORD" ] && ADMIN_COMPAT_PASSWORD="$(adb_val DEFAULT_PASSWORD)"
OLLAMA_BASE_URL="$(ini_val OLLAMA_BASE_URL)"; OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://host.docker.internal:11434}"
OLLAMA_MODEL="$(ini_val OLLAMA_MODEL)"; OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
EZCONNECT="//localhost:$DB_HOST_PORT/$ORACLE_PDB"

[ -n "$ORACLE_PWD" ] || die "ORACLE_PWD not set in ee/.env"
[ -n "$ADMIN_COMPAT_PASSWORD" ] || die "ADMIN_COMPAT_PASSWORD not set in ee/.env and adb/.env has no DEFAULT_PASSWORD to fall back on."

# Fail fast if the extracted APEX/ORDS distributions aren't there yet.
APEX_INSTALL_DIR="$(resolve_ee_path APEX_INSTALL_DIR ./apex-install)"
ORDS_INSTALL_DIR="$(resolve_ee_path ORDS_INSTALL_DIR ./ords-install)"
[ -f "$APEX_INSTALL_DIR/apexins.sql" ] || die "APEX not found under $APEX_INSTALL_DIR — run ./download-apex.sh first."
[ -x "$ORDS_INSTALL_DIR/bin/ords" ] || die "ORDS not found under $ORDS_INSTALL_DIR — run ./download-ords.sh first."

hdr "Starting oracle-db"
docker compose up -d oracle-db

echo "Waiting up to ${DB_HEALTHY_TIMEOUT}s for $CONTAINER_NAME to be healthy..."
start=$(date +%s)
while true; do
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -ge "$DB_HEALTHY_TIMEOUT" ] && die "Timeout waiting for $CONTAINER_NAME to become healthy."
    status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "starting")
    [ "$status" = "healthy" ] && { ok "$CONTAINER_NAME is healthy (${elapsed}s)"; break; }
    [ "$status" = "unhealthy" ] && die "$CONTAINER_NAME reported unhealthy — check: docker logs $CONTAINER_NAME"
    sleep 10
done

# Password-based EZConnect straight at the PDB service (not OS-authenticated
# bequeath "/") — this lands directly inside the PDB with no CDB$ROOT/ALTER
# SESSION dance needed, for any step that's pure SQL. sqlplus_setup_env
# (lib.sh) sets up EE_SQLPLUS + a clean TNS_ADMIN/LD_LIBRARY_PATH so we can
# invoke sqlplus directly with positional script args.
sqlplus_setup_env

hdr "Bootstrapping compat ADMIN user"
ADMIN_SQL="$(mktemp /tmp/ee_admin_XXXXXX.sql)"
sed -e "s/__ADMIN_PASSWORD__/$ADMIN_COMPAT_PASSWORD/g" \
    "$SCRIPT_DIR/sql-scripts/create-admin-compat-user.sql.tpl" > "$ADMIN_SQL"
ADMIN_OUT="$("$EE_SQLPLUS" -s "sys/$ORACLE_PWD@$EZCONNECT as sysdba" "@$ADMIN_SQL" 2>&1)"
rm -f "$ADMIN_SQL"
echo "$ADMIN_OUT"
echo "$ADMIN_OUT" | grep -qiE "SP2-|ORA-|PLS-" && die "Failed to bootstrap the compat ADMIN user — see sqlplus output above."
ok "Compat ADMIN user ready"

hdr "Checking for an existing APEX install"
CHECK_SQL="$(mktemp /tmp/ee_apexcheck_XXXXXX.sql)"
cat > "$CHECK_SQL" <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF
SELECT COUNT(*) FROM dba_users WHERE username LIKE 'APEX\_2%' ESCAPE '\' AND oracle_maintained = 'Y';
exit;
SQL
APEX_COUNT="$("$EE_SQLPLUS" -s "sys/$ORACLE_PWD@$EZCONNECT as sysdba" "@$CHECK_SQL" | tr -d '[:space:]')"
rm -f "$CHECK_SQL"

if [ "$APEX_COUNT" != "0" ]; then
    ok "APEX already installed in this PDB — skipping apexins.sql/apex_rest_config.sql (found $APEX_COUNT schema(s))."
else
    hdr "Installing APEX (apexins.sql — this takes a while, expect 15-30 minutes)"
    # apexins.sql's nested @@core/scripts/*.sql references only resolve
    # correctly when sqlplus's actual working directory is apexins.sql's own
    # directory AND it's invoked via a bare relative filename — a full-path
    # "@script args" invocation from a different cwd was tried and does NOT
    # work here despite matching Oracle's documented @@ semantics (confirmed
    # empirically). apexins.sql is pure SQL (no shell-outs), so it doesn't
    # need to run inside the container — just cd into its directory on the host.
    APEXINS_OUT="$(cd "$APEX_INSTALL_DIR" && "$EE_SQLPLUS" -s "sys/$ORACLE_PWD@$EZCONNECT as sysdba" "@apexins.sql" SYSAUX SYSAUX TEMP /i/ 2>&1)"
    echo "$APEXINS_OUT"
    echo "$APEXINS_OUT" | grep -qiE "SP2-|ORA-|PLS-" && die "apexins.sql failed — see sqlplus output above."
    ok "APEX installed"

    hdr "Configuring APEX_LISTENER / APEX_REST_PUBLIC_USER (apex_rest_config.sql)"
    # This one DOES need to run inside the container via docker exec: on a
    # CDB, apex_rest_config.sql shells out to $ORACLE_HOME/perl/.../catcon.pl
    # (a real Oracle Home, which only exists in the container, not on the
    # host's thin Instant Client) to iterate PDBs. Same cwd requirement as
    # apexins.sql applies — `docker exec -w` sets it to the container-internal
    # /tmp/apex mount, with a bare relative filename. It prompts (via ACCEPT,
    # or catcon.pl-forwarded prompts) for the APEX_LISTENER then
    # APEX_REST_PUBLIC_USER passwords, in that order — fed via stdin. Reusing
    # ORACLE_PWD for both is a deliberate POC shortcut.
    RESTCFG_OUT="$(printf '%s\n%s\n' "$ORACLE_PWD" "$ORACLE_PWD" \
        | docker exec -i -w /tmp/apex "$CONTAINER_NAME" sqlplus -s "sys/$ORACLE_PWD@localhost:1521/$ORACLE_PDB as sysdba" "@apex_rest_config.sql" 2>&1)"
    echo "$RESTCFG_OUT"
    echo "$RESTCFG_OUT" | grep -qiE "SP2-|ORA-|PLS-" && die "apex_rest_config.sql failed — see sqlplus output above."
    ok "APEX REST config complete"
fi

hdr "Starting ords (standalone install + serve)"
docker compose up -d ords

echo "Waiting up to ${ORDS_HEALTHY_TIMEOUT}s for ORDS to answer on port $APEX_PORT..."
start=$(date +%s)
while true; do
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -ge "$ORDS_HEALTHY_TIMEOUT" ] && die "Timeout waiting for ORDS on port $APEX_PORT. Check: docker logs $ORDS_CONTAINER_NAME"
    if curl -sf -o /dev/null "http://localhost:$APEX_PORT/ords/"; then
        ok "ORDS responding on port $APEX_PORT (${elapsed}s)"
        break
    fi
    sleep 10
done

hdr "Network/AI setup"
NET_SQL="$(mktemp /tmp/ee_net_XXXXXX.sql)"
sed -e "s|__OLLAMA_BASE_URL__|$OLLAMA_BASE_URL|g" \
    -e "s/__OLLAMA_MODEL__/$OLLAMA_MODEL/g" \
    "$SCRIPT_DIR/sql-scripts/setup-ee-network-ai.sql.tpl" > "$NET_SQL"
run_sql_ezconnect "ADMIN" "$ADMIN_COMPAT_PASSWORD" "$EZCONNECT" "$NET_SQL" \
    || warn "Network/AI setup script reported an error — review sqlplus output above (Ollama connectivity failure is non-fatal for this step)."
rm -f "$NET_SQL"

echo ""
ok "Stack is up."
echo "  APEX      : http://localhost:$APEX_PORT/ords/apex"
echo "  ORDS      : http://localhost:$APEX_PORT/ords/"
echo "  SQL*Net   : $EZCONNECT (ADMIN / <ADMIN_COMPAT_PASSWORD from ee/.env or adb/.env DEFAULT_PASSWORD>)"
echo ""
echo "  Verify with: ./test/smoke-ee.sh"
