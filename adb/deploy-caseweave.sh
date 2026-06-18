#!/usr/bin/env bash
# deploy-caseweave.sh
# Full Caseweave deployment: Oracle ADB + APEX app + ONNX model + Python workers.
#
# Steps:
#   1. Start Oracle ADB-Free container and stage ONNX model  (run-adb-26ai.sh)
#   2. Import Caseweave APEX app and load DOC_MODEL          (load-apex-app.sh -v)
#   3. Start all six Caseweave Python workers                (non-interactively)
#
# Usage: ./deploy-caseweave.sh [-c] [-k] [-h]
#   -c  Cleanup first: run run-adb-26ai.sh -c (stops container, prompts to wipe data dir)
#       then bring everything back up fresh. Workers are stopped before cleanup.
#   -k  Stop k3s before starting Oracle (frees 6-8 GB RAM for the container)
#   -h  Show this help

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
ADB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CASEWEAVE_DIR="/Users/tdaly/src/caseweave"
UTILS_DIR="$CASEWEAVE_DIR/utils"
VENV_DIR="$CASEWEAVE_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"
LOG_DIR="$UTILS_DIR/logs_weave32"
CREDS_FILE="$CASEWEAVE_DIR/.credentials"
APEX_SQL="$CASEWEAVE_DIR/apex-sql-src/Caseweave-local-mac-v2.sql"
VECTOR_SQL="$CASEWEAVE_DIR/apex-sql-src/Set_Up_Vector_Stuff.sql"
CONFIG_FILE="$ADB_DIR/config.ini"

SCRIPTS=(
  "weave32_MetaLLamaVision_v8.py"
  "weave32_zipfiles_photos_EXIF_LatLon_v4.py"
  "weave32_zipfiles_photos_v3.py"
  "weave32_peopleGraph_NodesAssocBrief_v7.py"
  "weave32_messageGraph_EdgesOnly_withPersons_v11.py"
  "weave32_conversationRecords_v12.py"
)

# ── Colour helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]] && tput colors &>/dev/null && [[ "$(tput colors)" -ge 8 ]]; then
  GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'
  BLD='\033[1m'; RST='\033[0m'
else
  GRN=''; RED=''; YLW=''; BLD=''; RST=''
fi

ok()   { printf "${GRN}  ✓${RST}  %s\n" "$*"; }
fail() { printf "${RED}  ✗${RST}  %s\n" "$*" >&2; }
warn() { printf "${YLW}  !${RST}  %s\n" "$*"; }
hdr()  { printf "\n${BLD}=== %s ===${RST}\n" "$*"; }

die() { fail "$*"; exit 1; }

# ── Config helpers ────────────────────────────────────────────────────────────
ini_val() {
  grep -m1 "^${1}=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*//' | tr -d ' \n\r'
}

DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD)
SERVICE_NAME=$(ini_val SERVICE_NAME)
CONTAINER_NAME=$(ini_val CONTAINER_NAME)
INSTANT_CLIENT=$(ini_val INSTANT_CLIENT_MAC)
[ -z "$INSTANT_CLIENT" ] && INSTANT_CLIENT=$(ini_val INSTANT_CLIENT)
ORACLE_CLIENT_DIR="$HOME/oraclient"
SQLPLUS="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus"

# ── Worker helpers (mirrors jobs.sh logic) ────────────────────────────────────
get_pid_file() { printf '%s/%s.pid' "$LOG_DIR" "${1%.py}"; }
get_log_file()  { printf '%s/%s.log' "$LOG_DIR" "${1%.py}"; }

is_running() {
  local pid_file; pid_file="$(get_pid_file "$1")"
  [[ -f "$pid_file" ]] || return 1
  local pid; pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

start_worker() {
  local script="$1"
  if is_running "$script"; then
    warn "$script already running (pid $(<"$(get_pid_file "$script")"))"
    return 0
  fi
  [[ -f "$UTILS_DIR/$script" ]] || die "$script not found at $UTILS_DIR/$script"
  local log; log="$(get_log_file "$script")"
  nohup bash -c "source '${VENV_DIR}/bin/activate' && python -u '${UTILS_DIR}/${script}'" \
    >> "$log" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$(get_pid_file "$script")"
  disown "$pid" 2>/dev/null || true
  ok "started $script (pid $pid)"
}

# ── Options ───────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [-c] [-k] [-h]
  -c  Cleanup first: stop workers, run run-adb-26ai.sh -c (interactive — prompts
      to remove data dir), then do a full fresh deploy
  -k  Stop k3s before starting Oracle (frees 6-8 GB RAM)
  -h  Show this help
EOF
  exit 0
}

K3S_FLAG=""
DO_CLEANUP=false
while getopts ":ckh" opt; do
  case $opt in
    c) DO_CLEANUP=true ;;
    k) K3S_FLAG="-k" ;;
    h) usage ;;
    \?) die "Unknown option: -$OPTARG" ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
hdr "Pre-flight checks"

[[ -f "$CONFIG_FILE" ]]  || die "config.ini not found: $CONFIG_FILE"
[[ -f "$APEX_SQL" ]]     || die "APEX export not found: $APEX_SQL"
[[ -f "$VECTOR_SQL" ]]   || die "Vector setup SQL not found: $VECTOR_SQL"
[[ -f "$CREDS_FILE" ]]   || die ".credentials not found: $CREDS_FILE — workers cannot connect to DB"
[[ -f "$VENV_PYTHON" ]]  || die "Python venv not found at $VENV_DIR — run 'i' in jobs.sh first"
[[ -x "$SQLPLUS" ]]      || die "sqlplus not found at $SQLPLUS — run setup-for-adb-26ai.sh first"

ok "config.ini found"
ok "APEX export found: $(basename "$APEX_SQL")"
ok "Vector SQL found: $(basename "$VECTOR_SQL")"
ok "credentials file found"
ok "Python venv found ($("$VENV_PYTHON" --version 2>&1))"
ok "sqlplus found"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Oracle ADB-Free container + ONNX staging
# ─────────────────────────────────────────────────────────────────────────────
hdr "Step 1: Oracle ADB-Free container"

if [[ "$DO_CLEANUP" == "true" ]]; then
  warn "Cleanup requested — stopping workers before container teardown"
  for _s in "${SCRIPTS[@]}"; do
    _spid_file="$(get_pid_file "$_s")"
    if [[ -f "$_spid_file" ]]; then
      _spid="$(<"$_spid_file")"
      kill "$_spid" 2>/dev/null || true
      rm -f "$_spid_file"
      ok "Stopped $_s (pid $_spid)"
    fi
  done
  warn "Running run-adb-26ai.sh -c — you will be prompted about the data dir"
  "$ADB_DIR/run-adb-26ai.sh" -c
  warn "Cleanup done — starting fresh"
  "$ADB_DIR/run-adb-26ai.sh" $K3S_FLAG
  ok "Container '$CONTAINER_NAME' started fresh"
else
  _health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  if [[ "$_health" == "healthy" ]]; then
    ok "Container '$CONTAINER_NAME' already healthy — skipping run-adb-26ai.sh"
  else
    warn "Container '$CONTAINER_NAME' not running (status: $_health) — starting via run-adb-26ai.sh"
    "$ADB_DIR/run-adb-26ai.sh" $K3S_FLAG
    _health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    [[ "$_health" == "healthy" ]] \
      || die "Container '$CONTAINER_NAME' not healthy after startup (status: $_health)"
    ok "Container '$CONTAINER_NAME' is healthy"
  fi
fi

# Verify sqlplus can connect and ONNX_STAGING directory exists
_dir_check=$(TNS_ADMIN="$HOME/auth/tls_wallet" \
  DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" \
  "$SQLPLUS" -s "admin/$DEFAULT_PASSWORD@$SERVICE_NAME" <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM dba_directories WHERE directory_name = 'ONNX_STAGING';
EXIT;
EOF
)
_dir_check=$(echo "$_dir_check" | tr -d '[:space:]')
[[ "$_dir_check" == "1" ]] \
  || die "ONNX_STAGING not in Oracle — run 'run-adb-26ai.sh' first to set up the container"
ok "ONNX_STAGING directory present in Oracle"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — APEX app import + DOC_MODEL load
# ─────────────────────────────────────────────────────────────────────────────
hdr "Step 2: Caseweave APEX app + DOC_MODEL"

"$ADB_DIR/load-apex-app.sh" -f "$APEX_SQL" -v "$VECTOR_SQL"

# Verify DOC_MODEL loaded
_model_check=$(TNS_ADMIN="$HOME/auth/tls_wallet" \
  DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" \
  "$SQLPLUS" -s "admin/$DEFAULT_PASSWORD@$SERVICE_NAME" <<'EOF'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM user_mining_models WHERE model_name = 'DOC_MODEL';
EXIT;
EOF
)
_model_check=$(echo "$_model_check" | tr -d '[:space:]')
[[ "$_model_check" == "1" ]] \
  || die "DOC_MODEL not found in user_mining_models after load — check Set_Up_Vector_Stuff.sql output above"
ok "DOC_MODEL loaded in Oracle"

# Verify WEAVE32 can see DOC_MODEL (confirms grant) — connect via .credentials
if "$VENV_PYTHON" -c "
import oracledb, configparser
c = configparser.ConfigParser(); c.read('$CREDS_FILE')
cr = c['local_weave32']
wloc = cr.get('wallet_location','').strip()
wpass = cr.get('wallet_password','').strip()
if wloc:
    conn = oracledb.connect(user=cr['user'], password=cr['password'], dsn=cr['dsn'],
                            config_dir=wloc, wallet_location=wloc, wallet_password=wpass or None)
else:
    conn = oracledb.connect(user=cr['user'], password=cr['password'], dsn=cr['dsn'])
cur = conn.cursor()
cur.execute(\"SELECT COUNT(*) FROM all_mining_models WHERE model_name = 'DOC_MODEL'\")
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null | grep -q "^1$"; then
  ok "DOC_MODEL accessible to WEAVE32 (grant confirmed)"
else
  warn "DOC_MODEL not visible to WEAVE32 — page 15 vector search may fail"
fi

# Verify APEX app installed (detect app ID from export)
_app_id=$(grep -m1 "p_default_application_id" "$APEX_SQL" \
  | sed "s/.*p_default_application_id=>['\">]*\([0-9]*\).*/\1/" | tr -d ' \r\n')
if [[ -n "$_app_id" ]]; then
  _app_check=$(TNS_ADMIN="$HOME/auth/tls_wallet" \
    DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" \
    "$SQLPLUS" -s "admin/$DEFAULT_PASSWORD@$SERVICE_NAME" <<EOF
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT COUNT(*) FROM apex_applications WHERE application_id = $_app_id;
EXIT;
EOF
  )
  _app_check=$(echo "$_app_check" | tr -d '[:space:]')
  [[ "$_app_check" == "1" ]] \
    || die "APEX app $_app_id not found after import — check load-apex-app.sh output above"
  ok "APEX app $_app_id installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Python workers
# ─────────────────────────────────────────────────────────────────────────────
hdr "Step 3: Caseweave Python workers"

mkdir -p "$LOG_DIR"

# Check DB connectivity via the worker credentials before starting
if "$VENV_PYTHON" -c "
import oracledb, configparser
c = configparser.ConfigParser(); c.read('$CREDS_FILE')
cr = c['local_weave32']
wloc = cr.get('wallet_location','').strip()
wpass = cr.get('wallet_password','').strip()
if wloc:
    conn = oracledb.connect(user=cr['user'], password=cr['password'], dsn=cr['dsn'],
                            config_dir=wloc, wallet_location=wloc, wallet_password=wpass or None)
else:
    conn = oracledb.connect(user=cr['user'], password=cr['password'], dsn=cr['dsn'])
conn.close()
" 2>/dev/null; then
  ok "Worker DB connection OK"
else
  die "Workers cannot connect to DB — check .credentials wallet_location and Oracle container"
fi

for script in "${SCRIPTS[@]}"; do
  start_worker "$script"
done

# Brief settle time then verify all are alive
sleep 3
echo ""
printf "${BLD}  Worker status after 3s:${RST}\n"
_all_ok=true
for script in "${SCRIPTS[@]}"; do
  if is_running "$script"; then
    printf "${GRN}  ✓${RST}  %-55s pid %s\n" "$script" "$(<"$(get_pid_file "$script")")"
  else
    printf "${RED}  ✗${RST}  %-55s FAILED — check %s\n" "$script" "$(get_log_file "$script")"
    _all_ok=false
  fi
done

echo ""
[[ "$_all_ok" == "true" ]] \
  || die "One or more workers failed to stay up — check logs in $LOG_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
_apex_port=$(ini_val APEX_PORT); _apex_port=${_apex_port:-8443}
printf "\n${GRN}${BLD}=== Caseweave deployed successfully ===${RST}\n\n"
printf "  APEX:       https://localhost:$_apex_port/ords/apex\n"
printf "  Workspace:  WEAVE32   User: WEAVE32   Password: $DEFAULT_PASSWORD\n"
printf "  Workers:    %d running — logs in %s\n" "${#SCRIPTS[@]}" "$LOG_DIR"
printf "  Manage:     cd %s && bash jobs.sh\n\n" "$UTILS_DIR"
