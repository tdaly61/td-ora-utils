#!/usr/bin/env bash
# load-apex-app.sh
# Loads an APEX application export SQL file into the running Oracle ADB environment.
#
# The parsing schema and APEX workspace are auto-detected from the export file.
# If the schema or workspace do not exist they are created automatically.
#
# Usage:
#   ./load-apex-app.sh [-f <apex_export.sql>] [-u <schema_user>] [-p <password>]
#                      [-s <service_name>] [-r STATIC_ID=https://...] [-h]
#
# Options:
#   -f  Path to the APEX export SQL file (prompted if not supplied)
#   -u  Override the Oracle schema / APEX workspace user
#       (default: auto-detected from p_default_owner in the export file)
#   -p  Password for the schema user
#       (default: APEX_PASSWORD from config.ini, else DEFAULT_PASSWORD)
#   -s  Oracle service name  (default: SERVICE_NAME from config.ini)
#   -r  Override base URL for a remote server marked prompt_on_install in the export
#       Format: STATIC_ID=https://endpoint  (repeat for multiple servers)
#       Supported IDs: OCI_GROK_BIG, META_LLAMA_33_70B_INSTRUCT
#       (default: URLs extracted from the export file)
#   -h  Show this help message
#
# Prerequisites:
#   - Oracle ADB container is running  (run-adb-26ai.sh completed)
#   - Oracle Instant Client (sqlplus) installed at ~/oraclient/<INSTANT_CLIENT>/
#   - config.ini present in the same directory as this script

set -euo pipefail

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="$RUN_DIR/config.ini"

# ── Usage / Help ──────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Loads an APEX application export SQL file into a running Oracle ADB environment.
The parsing schema and APEX workspace are auto-detected from the export file.
If the schema or workspace do not exist they are created automatically.

Options:
  -f <file>           Path to the APEX export SQL file
                      (prompted interactively if not supplied)
  -u <schema_user>    Override the Oracle schema / APEX workspace user
                      (default: auto-detected from p_default_owner in the export)
  -p <password>       Password for the schema user
                      (default: APEX_PASSWORD from config.ini, else DEFAULT_PASSWORD)
  -s <service_name>   Oracle service name
                      (default: SERVICE_NAME from config.ini)
  -r STATIC_ID=URL    Override the base URL for a remote server at install time.
                      Repeat the flag for multiple servers.
                      Default URLs come from LLM_<STATIC_ID> entries in config.ini.
                      Example: -r OCI_GROK_BIG=https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com
  -h                  Show this help message and exit

Prerequisites:
  - Oracle ADB container is running  (run-adb-26ai.sh completed)
  - Oracle Instant Client (sqlplus) installed at ~/oraclient/<INSTANT_CLIENT>/
  - config.ini present in the same directory as this script

Examples:
  $(basename "$0") -f /tmp/f316.sql
  $(basename "$0") -f /tmp/f316.sql -u MYSCHEMA -p MyPass1
  $(basename "$0") -f /tmp/f316.sql -r OCI_GROK_BIG=https://inference.generativeai.eu-frankfurt-1.oci.oraclecloud.com
EOF
  exit 0
}

# Early -h check: must come after usage() is defined, before config.ini is required
for _arg in "$@"; do
  [[ "$_arg" == "-h" ]] && usage
  [[ "$_arg" == "--" ]] && break
done
unset _arg

# ── Read config.ini ───────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.ini not found in $RUN_DIR"
  exit 1
fi

cfg_val() {
  awk -F "=" "/^${1}[[:space:]]*=/ {print \$2}" "$CONFIG_FILE" | tr -d ' \n\r'
}

DEFAULT_PASSWORD=$(cfg_val DEFAULT_PASSWORD)
SERVICE_NAME=$(cfg_val SERVICE_NAME)
INSTANT_CLIENT=$(cfg_val INSTANT_CLIENT)
APEX_PORT=$(cfg_val APEX_PORT);     APEX_PORT=${APEX_PORT:-8080}
APEX_USER=$(cfg_val APEX_USER);     APEX_USER=${APEX_USER:-TRACKER1}
APEX_PASSWORD=$(cfg_val APEX_PASSWORD); APEX_PASSWORD=${APEX_PASSWORD:-$DEFAULT_PASSWORD}
# Read LLM_<STATIC_ID>=<url>|<model>|<type> entries from config.ini
declare -A LLM_URL=()
declare -A LLM_MODEL=()
declare -A LLM_TYPE=()
while IFS= read -r _cfg_line; do
  if [[ "$_cfg_line" =~ ^LLM_([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*([^|]+)\|([^|]+)\|([^|[:space:]]+) ]]; then
    LLM_URL["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    LLM_MODEL["${BASH_REMATCH[1]}"]="${BASH_REMATCH[3]}"
    LLM_TYPE["${BASH_REMATCH[1]}"]="${BASH_REMATCH[4]}"
  fi
done < "$CONFIG_FILE"

# ── Parse options ─────────────────────────────────────────────────────────────
APEX_SQL=""
OVERRIDE_USER=""
OVERRIDE_PASS=""
declare -A RS_OVERRIDES=()

while getopts ":f:u:p:s:r:h" opt; do
  case $opt in
    f) APEX_SQL="$OPTARG" ;;
    u) OVERRIDE_USER="$OPTARG" ;;
    p) OVERRIDE_PASS="$OPTARG" ;;
    s) SERVICE_NAME="$OPTARG" ;;
    r) # FORMAT:  STATIC_ID=https://...
       _rs_id="${OPTARG%%=*}"
       _rs_url="${OPTARG#*=}"
       RS_OVERRIDES["$_rs_id"]="$_rs_url" ;;
    h) usage ;;
    :) echo "ERROR: -$OPTARG requires an argument."; exit 1 ;;
    \?) echo "ERROR: Unknown option -$OPTARG"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

# Merge LLM config URLs with any -r overrides (overrides win), then build Step 2 PL/SQL
declare -A RS_FINAL=()
for _rs_key in "${!LLM_URL[@]}"; do
  RS_FINAL["$_rs_key"]="${RS_OVERRIDES[$_rs_key]:-${LLM_URL[$_rs_key]}}"
done
for _rs_key in "${!RS_OVERRIDES[@]}"; do
  RS_FINAL["$_rs_key"]="${RS_OVERRIDES[$_rs_key]}"
done

_RS_BLOCK=""
for _rs_key in "${!RS_FINAL[@]}"; do
  [ -z "$_RS_BLOCK" ] && _RS_BLOCK="BEGIN"$'\n'
  _RS_BLOCK+="  apex_application_install.set_remote_server(p_static_id => '${_rs_key}', p_base_url => '${RS_FINAL[$_rs_key]}');"$'\n'
done
[ -n "$_RS_BLOCK" ] && _RS_BLOCK+="  DBMS_OUTPUT.PUT_LINE('Remote server base URLs set.');"$'\n'"END;"$'\n'"/"

# ── Resolve APEX export file ──────────────────────────────────────────────────
if [ -z "$APEX_SQL" ]; then
  echo ""
  read -r -p "Enter path to APEX export SQL file: " APEX_SQL
fi

APEX_SQL="${APEX_SQL/#\~/$HOME}"
APEX_SQL="$(realpath -m "$APEX_SQL" 2>/dev/null || echo "$APEX_SQL")"

if [ ! -f "$APEX_SQL" ]; then
  echo "ERROR: APEX export file not found: $APEX_SQL"
  exit 1
fi

# ── Auto-detect parsing schema and app ID from export header ──────────────────
# The export contains: ,p_default_owner=>'SCHEMANAME'
DETECTED_OWNER=$(grep -m1 "p_default_owner" "$APEX_SQL" \
  | sed "s/.*p_default_owner=>['\"]\\([^'\"]*\\)['\"].*/\\1/" \
  | tr -d ' \r\n')

# The export contains: ,p_default_application_id=>316
DETECTED_APP_ID=$(grep -m1 "p_default_application_id" "$APEX_SQL" \
  | sed "s/.*p_default_application_id=>['\">]*\([0-9]*\).*/\\1/" \
  | tr -d ' \r\n')

if [ -n "$OVERRIDE_USER" ]; then
  SCHEMA_USER="$OVERRIDE_USER"
elif [ -n "$DETECTED_OWNER" ]; then
  SCHEMA_USER="$DETECTED_OWNER"
else
  # Fall back to APEX_USER from config
  SCHEMA_USER="$APEX_USER"
  echo "WARN: Could not detect p_default_owner from export — using config APEX_USER: $SCHEMA_USER"
fi

SCHEMA_USER_UPPER="${SCHEMA_USER^^}"

# Password: explicit override → config APEX_PASSWORD → DEFAULT_PASSWORD
if [ -n "$OVERRIDE_PASS" ]; then
  SCHEMA_PASS="$OVERRIDE_PASS"
else
  SCHEMA_PASS="$APEX_PASSWORD"
fi

# ── Locate sqlplus ────────────────────────────────────────────────────────────
ORACLE_CLIENT_DIR="$HOME/oraclient"
SQLPLUS="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus"

if [ ! -x "$SQLPLUS" ]; then
  if command -v sqlplus &>/dev/null; then
    SQLPLUS="sqlplus"
  else
    echo "ERROR: sqlplus not found at $SQLPLUS and not on PATH."
    echo "Run sudo ./setup-for-adb-26ai.sh first, or install Oracle Instant Client."
    exit 1
  fi
fi

export TNS_ADMIN="$HOME/auth/tns"
export LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== load-apex-app.sh ==="
echo "  APEX export  : $APEX_SQL"
if [ -n "$DETECTED_OWNER" ] && [ -z "$OVERRIDE_USER" ]; then
  echo "  Schema user  : $SCHEMA_USER_UPPER  (auto-detected from export)"
else
  echo "  Schema user  : $SCHEMA_USER_UPPER"
fi
echo "  App ID       : ${DETECTED_APP_ID:-unknown}"
echo "  Service      : $SERVICE_NAME"
echo "  SQLPlus      : $SQLPLUS"
echo ""

# ── Step 1: Bootstrap schema + APEX workspace as SYS (idempotent) ─────────────
# Creates the Oracle DB user and APEX workspace/admin user only if they don't
# already exist. Safe to re-run — all operations are guarded by existence checks.
echo "=== Step 1: Bootstrapping schema and APEX workspace for $SCHEMA_USER_UPPER ==="

"$SQLPLUS" -s "sys/$DEFAULT_PASSWORD@$SERVICE_NAME as sysdba" << SYSDBA_EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
  v_user_exists    NUMBER;
  v_apex_installed NUMBER;
  v_ws_exists      NUMBER;
BEGIN

  -- ── 1a. Create Oracle schema if it does not exist ──────────────────────────
  SELECT COUNT(*) INTO v_user_exists
  FROM   dba_users
  WHERE  username = UPPER('$SCHEMA_USER_UPPER');

  IF v_user_exists = 0 THEN
    EXECUTE IMMEDIATE
      'CREATE USER $SCHEMA_USER_UPPER IDENTIFIED BY "$SCHEMA_PASS"';
    EXECUTE IMMEDIATE
      'GRANT CONNECT, RESOURCE, UNLIMITED TABLESPACE TO $SCHEMA_USER_UPPER';
    EXECUTE IMMEDIATE
      'GRANT CREATE VIEW, CREATE MATERIALIZED VIEW, CREATE PROCEDURE TO $SCHEMA_USER_UPPER';
    EXECUTE IMMEDIATE
      'GRANT DB_DEVELOPER_ROLE, CREATE MINING MODEL TO $SCHEMA_USER_UPPER';
    EXECUTE IMMEDIATE
      'GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO $SCHEMA_USER_UPPER';
    DBMS_OUTPUT.PUT_LINE('Oracle schema $SCHEMA_USER_UPPER created.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Oracle schema $SCHEMA_USER_UPPER already exists — skipped.');
  END IF;

  -- ── 1b. Create APEX workspace + admin user if APEX is installed ────────────
  SELECT COUNT(*) INTO v_apex_installed
  FROM   dba_users
  WHERE  username = 'APEX_PUBLIC_USER';

  IF v_apex_installed = 0 THEN
    DBMS_OUTPUT.PUT_LINE('APEX not installed — skipping workspace setup.');
    RETURN;
  END IF;

  SELECT COUNT(*) INTO v_ws_exists
  FROM   apex_workspaces
  WHERE  workspace = UPPER('$SCHEMA_USER_UPPER');

  IF v_ws_exists = 0 THEN
    EXECUTE IMMEDIATE
      'BEGIN apex_instance_admin.add_workspace(' ||
      '  p_workspace => ''$SCHEMA_USER_UPPER'',' ||
      '  p_primary_schema => ''$SCHEMA_USER_UPPER''); END;';
    DBMS_OUTPUT.PUT_LINE('APEX workspace $SCHEMA_USER_UPPER created.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('APEX workspace $SCHEMA_USER_UPPER already exists — skipped.');
  END IF;

  -- ── 1c. Create APEX admin user in the workspace if not present ─────────────
  EXECUTE IMMEDIATE
    'BEGIN apex_util.set_workspace(p_workspace => ''$SCHEMA_USER_UPPER''); END;';

  DECLARE
    v_apex_user_exists NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_apex_user_exists
    FROM   apex_workspace_apex_users
    WHERE  workspace_name = UPPER('$SCHEMA_USER_UPPER')
    AND    user_name      = UPPER('$SCHEMA_USER_UPPER');

    IF v_apex_user_exists = 0 THEN
      EXECUTE IMMEDIATE q'[BEGIN
        apex_util.create_user(
          p_user_name                 => '$SCHEMA_USER_UPPER',
          p_web_password              => '$SCHEMA_PASS',
          p_developer_privs           => 'ADMIN:CREATE:DATA_LOADER:EDIT:HELP:MONITOR:SQL',
          p_email_address             => '$SCHEMA_USER_UPPER@local',
          p_default_schema            => '$SCHEMA_USER_UPPER',
          p_account_expiry            => SYSDATE + 36500,
          p_change_password_on_first_use => 'N');
      END;]';
      DBMS_OUTPUT.PUT_LINE('APEX admin user $SCHEMA_USER_UPPER created in workspace.');
    ELSE
      DBMS_OUTPUT.PUT_LINE('APEX admin user $SCHEMA_USER_UPPER already exists — skipped.');
    END IF;
  END;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Bootstrap complete.');

EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('Bootstrap FAILED: ' || SQLERRM);
  RAISE;
END;
/
exit
SYSDBA_EOF

echo "Bootstrap step complete."

# ── Step 2: Import the APEX application as the parsing schema user ─────────────
# The export's p_default_workspace_id is from the source environment and won't
# match the target. We must call apex_application_install.set_workspace_id with
# the actual workspace_id in this environment before running the import, otherwise
# wwv_flow_imp.import_begin raises ORA-20001: g_security_group_id must be set.
#
# A temporary wrapper SQL is generated, used, then deleted.
echo ""
echo "=== Step 2: Importing APEX application as $SCHEMA_USER_UPPER ==="

WRAPPER_SQL=$(mktemp /tmp/apex_import_XXXXXX.sql)
trap 'rm -f "$WRAPPER_SQL"' EXIT

cat > "$WRAPPER_SQL" << WRAPPER_EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
SET DEFINE OFF VERIFY OFF FEEDBACK OFF SERVEROUTPUT ON SIZE UNLIMITED

-- 1. Resolve the workspace ID in this environment and set it so that
--    wwv_flow_imp.import_begin can populate g_security_group_id correctly.
DECLARE
  l_ws_id NUMBER;
BEGIN
  SELECT workspace_id INTO l_ws_id
  FROM   apex_workspaces
  WHERE  workspace = UPPER('$SCHEMA_USER_UPPER');
  apex_application_install.set_workspace_id(l_ws_id);
  DBMS_OUTPUT.PUT_LINE('Workspace ID set: ' || l_ws_id);
END;
/

-- 2. Enable automatic installation of Supporting Objects (tables, sequences, etc.)
--    Without this, p_auto_install_sup_obj defaults to false and the schema DDL is skipped.
BEGIN
  apex_application_install.set_auto_install_sup_obj(p_auto_install_sup_obj => true);
  DBMS_OUTPUT.PUT_LINE('Auto-install supporting objects: enabled.');
END;
/

-- 3. Pre-supply base URLs for remote servers marked p_prompt_on_install=>true.
--    Without this, wwv_imp_workspace.create_remote_server raises ORA-20001.
--    Entries are read from LLM_* keys in config.ini; override with -r flags.
$_RS_BLOCK

@$APEX_SQL
exit
WRAPPER_EOF

"$SQLPLUS" -s "$SCHEMA_USER_UPPER/$SCHEMA_PASS@$SERVICE_NAME" "@$WRAPPER_SQL"
echo "Import complete."

# ── Step 3: Grant ADMINISTRATOR role to the workspace admin user ───────────────
# The app uses APEX_ACL role-based authorization. Without a role assignment the
# workspace admin gets APEX.AUTHORIZATION.ACCESS_DENIED on first login.
# We grant ADMINISTRATOR to SCHEMA_USER so the install is immediately usable.
# Additional users can be added afterwards (e.g. via weave31_users.sql).
echo ""
echo "=== Step 3: Granting ADMINISTRATOR role to $SCHEMA_USER_UPPER in app $DETECTED_APP_ID ==="

"$SQLPLUS" -s "$SCHEMA_USER_UPPER/$SCHEMA_PASS@$SERVICE_NAME" << ACL_EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

BEGIN
  apex_util.set_workspace(p_workspace => '$SCHEMA_USER_UPPER');
END;
/

DECLARE
  v_exists NUMBER;
BEGIN
  -- Idempotent: only add if not already present
  SELECT COUNT(*) INTO v_exists
  FROM   apex_appl_acl_user_roles
  WHERE  application_id = $DETECTED_APP_ID
  AND    user_name      = UPPER('$SCHEMA_USER_UPPER')
  AND    role_static_id = 'ADMINISTRATOR';

  IF v_exists = 0 THEN
    APEX_ACL.ADD_USER_ROLE(
      p_application_id => $DETECTED_APP_ID,
      p_user_name      => '$SCHEMA_USER_UPPER',
      p_role_static_id => 'ADMINISTRATOR'
    );
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ADMINISTRATOR role granted to $SCHEMA_USER_UPPER.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('$SCHEMA_USER_UPPER already has ADMINISTRATOR role — skipped.');
  END IF;
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('Role grant warning: ' || SQLERRM);
  DBMS_OUTPUT.PUT_LINE('App may not use ACL roles — this is non-fatal.');
END;
/
exit
ACL_EOF
echo "Role step complete."

# ── Step 4: Configure local LLM AI services for the app workspace ──────────────
# Runs for each LLM_* entry with type=local in config.ini.
# Creates (or updates) an encrypted APEX workspace credential and Generative AI
# remote server entry.  The credential secret is stored via the APEX API so it
# is properly encrypted — direct SQL INSERT leaves plaintext and causes ORA-28817.
_local_llm_count=0
for _LLM_ID in "${!LLM_TYPE[@]}"; do
  [ "${LLM_TYPE[$_LLM_ID]}" != "local" ] && continue
  _local_llm_count=$((_local_llm_count + 1))
  _LLM_API_URL="${LLM_URL[$_LLM_ID]%/}/v1"
  _LLM_MODEL="${LLM_MODEL[$_LLM_ID]}"
  _LLM_CRED_SID="${_LLM_ID}_CRED"
  echo ""
  echo "=== Step 4: Configuring local LLM '${_LLM_ID}' for $SCHEMA_USER_UPPER ==="

  "$SQLPLUS" -s "system/$DEFAULT_PASSWORD@$SERVICE_NAME" << OLLAMA_EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

DECLARE
  v_ws_id      NUMBER;
  v_apex_owner VARCHAR2(128);
  v_cred_id    NUMBER;
  v_srv_id     NUMBER;
  v_static_id  VARCHAR2(100) := '$_LLM_ID';
  v_cred_sid   VARCHAR2(100) := '$_LLM_CRED_SID';
  v_base_url   VARCHAR2(500) := '$_LLM_API_URL';
  v_model      VARCHAR2(100) := '$_LLM_MODEL';
  v_sql        VARCHAR2(4000);
BEGIN
  SELECT workspace_id INTO v_ws_id
    FROM apex_workspaces
   WHERE workspace = UPPER('$SCHEMA_USER_UPPER');

  SELECT username INTO v_apex_owner
    FROM dba_users
   WHERE username LIKE 'APEX_%'
     AND oracle_maintained = 'Y'
     AND username NOT IN ('APEX_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','APEX_PUBLIC_ROUTER')
     AND ROWNUM = 1;

  -- Step A: Create or locate the workspace credential row (secret set in step B)
  v_sql := 'SELECT id FROM ' || v_apex_owner || '.wwv_credentials'
        || ' WHERE security_group_id = :ws AND static_id = :sid';
  BEGIN
    EXECUTE IMMEDIATE v_sql INTO v_cred_id USING v_ws_id, v_cred_sid;
    DBMS_OUTPUT.PUT_LINE('Credential ' || v_cred_sid || ' exists (id=' || v_cred_id || ') — will re-encrypt.');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_sql := 'SELECT ' || v_apex_owner || '.wwv_seq.nextval FROM dual';
      EXECUTE IMMEDIATE v_sql INTO v_cred_id;
      v_sql := 'INSERT INTO ' || v_apex_owner || '.wwv_credentials'
            || ' (id, security_group_id, name, static_id,'
            || '  authentication_type, client_id,'
            || '  prompt_on_install,'
            || '  created_by, created_on, last_updated_by, last_updated_on)'
            || ' VALUES (:id, :ws, :nm, :sid,'
            || '  ''HTTP_HEADER'', ''Authorization'','
            || '  ''Y'','
            || '  USER, SYSDATE, USER, SYSDATE)';
      EXECUTE IMMEDIATE v_sql USING v_cred_id, v_ws_id, v_static_id || ' Credential', v_cred_sid;
      DBMS_OUTPUT.PUT_LINE('Credential created: ' || v_cred_sid);
  END;

  -- Step B: Encrypt the secret via APEX API.
  --   Direct INSERT of plaintext raises ORA-28817 at runtime.
  apex_util.set_workspace(p_workspace => '$SCHEMA_USER_UPPER');
  apex_credential.set_persistent_credentials(
    p_credential_static_id => v_cred_sid,
    p_key                  => 'Authorization',
    p_value                => 'Bearer ollama-no-auth-needed'
  );
  DBMS_OUTPUT.PUT_LINE('Credential secret encrypted.');

  -- Step C: Create or update the Generative AI remote server entry
  v_sql := 'SELECT id FROM ' || v_apex_owner || '.wwv_remote_servers'
        || ' WHERE security_group_id = :ws AND static_id = :sid';
  BEGIN
    EXECUTE IMMEDIATE v_sql INTO v_srv_id USING v_ws_id, v_static_id;
    v_sql := 'UPDATE ' || v_apex_owner || '.wwv_remote_servers'
          || ' SET base_url = :url, ai_model_name = :mdl,'
          || '     credential_id = :cid,'
          || '     last_updated_on = SYSDATE, last_updated_by = USER'
          || ' WHERE id = :id';
    EXECUTE IMMEDIATE v_sql USING v_base_url, v_model, v_cred_id, v_srv_id;
    DBMS_OUTPUT.PUT_LINE('AI service updated: ' || v_static_id || ' -> ' || v_base_url || ' (' || v_model || ')');
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      v_sql := 'SELECT ' || v_apex_owner || '.wwv_seq.nextval FROM dual';
      EXECUTE IMMEDIATE v_sql INTO v_srv_id;
      v_sql := 'INSERT INTO ' || v_apex_owner || '.wwv_remote_servers'
            || ' (id, security_group_id, name, static_id, base_url,'
            || '  server_type, ai_provider_type, ai_is_builder_service,'
            || '  ai_model_name, credential_id, prompt_on_install,'
            || '  created_by, created_on, last_updated_by, last_updated_on)'
            || ' VALUES (:id, :ws, :nm, :sid, :url,'
            || '  ''GENERATIVE_AI'', ''OPENAI'', ''N'','
            || '  :mdl, :cid, ''Y'','
            || '  USER, SYSDATE, USER, SYSDATE)';
      EXECUTE IMMEDIATE v_sql USING v_srv_id, v_ws_id,
        v_static_id, v_static_id, v_base_url, v_model, v_cred_id;
      DBMS_OUTPUT.PUT_LINE('AI service created: ' || v_static_id || ' -> ' || v_base_url || ' (' || v_model || ')');
  END;

  COMMIT;
END;
/
exit
OLLAMA_EOF
  echo "Local LLM service step complete: $_LLM_ID"
done
if [ "$_local_llm_count" -eq 0 ]; then
  echo ""
  echo "=== Step 4: Skipped — no local LLM entries (type=local) in config.ini ==="
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== APEX application loaded successfully ==="
echo "  Browse to : http://localhost:$APEX_PORT/ords/f"
echo ""
echo "  APEX Login:"
echo "    Workspace : $SCHEMA_USER_UPPER"
echo "    Username  : $SCHEMA_USER_UPPER"
echo "    Password  : $SCHEMA_PASS"
echo ""
echo "  SSH tunnel (if remote):"
echo "    ssh -L $APEX_PORT:localhost:$APEX_PORT -N ubuntu@<server-ip>"
