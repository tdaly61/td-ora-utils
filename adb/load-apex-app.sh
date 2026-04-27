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
  -r STATIC_ID=URL    Override base URL for a remote server marked prompt_on_install
                      in the export file.  Repeat the flag for multiple servers.
                      Supported IDs:
                        OCI_GROK_BIG
                        META_LLAMA_33_70B_INSTRUCT
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

# ── Parse options ─────────────────────────────────────────────────────────────
APEX_SQL=""
OVERRIDE_USER=""
OVERRIDE_PASS=""
RS_OCI_GROK_BIG=""
RS_META_LLAMA=""

while getopts ":f:u:p:s:r:h" opt; do
  case $opt in
    f) APEX_SQL="$OPTARG" ;;
    u) OVERRIDE_USER="$OPTARG" ;;
    p) OVERRIDE_PASS="$OPTARG" ;;
    s) SERVICE_NAME="$OPTARG" ;;
    r) # FORMAT:  STATIC_ID=https://...
       _rs_id="${OPTARG%%=*}"
       _rs_url="${OPTARG#*=}"
       case "$_rs_id" in
         OCI_GROK_BIG)           RS_OCI_GROK_BIG="$_rs_url" ;;
         META_LLAMA_33_70B_INSTRUCT) RS_META_LLAMA="$_rs_url" ;;
         *) echo "WARN: Unknown remote server static ID '$_rs_id' — ignored." ;;
       esac ;;
    h) usage ;;
    :) echo "ERROR: -$OPTARG requires an argument."; exit 1 ;;
    \?) echo "ERROR: Unknown option -$OPTARG"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

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

-- 2. Pre-supply base URLs for remote servers marked p_prompt_on_install=>true.
--    Without this, wwv_imp_workspace.create_remote_server raises ORA-20001.
--    The URLs below are extracted from the export file and match the source env;
--    override with -r flags if the target uses a different OCI region/endpoint.
BEGIN
  apex_application_install.set_remote_server(
    p_static_id => 'OCI_GROK_BIG',
    p_base_url  => nvl('$RS_OCI_GROK_BIG', 'https://inference.generativeai.us-chicago-1.oci.oraclecloud.com')
  );
  apex_application_install.set_remote_server(
    p_static_id => 'META_LLAMA_33_70B_INSTRUCT',
    p_base_url  => nvl('$RS_META_LLAMA', 'https://inference.generativeai.us-chicago-1.oci.oraclecloud.com')
  );
  DBMS_OUTPUT.PUT_LINE('Remote server base URLs set.');
END;
/

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
