#!/usr/bin/env bash
# export-apex-app.sh
# Exports a live APEX application (its Supporting Objects carry the schema) to a
# versioned SQL file + manifest. Generic — works for any APEX app/workspace, not
# tied to any one application.
#
# The export-side counterpart to load-apex-app.sh (this directory). Defaults
# to the FREEPDB1 service, plain EZConnect (no wallet), reads dbfree/.env.
#
# Usage:
#   ./export-apex-app.sh -u <schema_user> [-a <app_id>] [-p <password>]
#                         [-s <service_name>] [-d <output_dir>] [-N <name_prefix>]
#                         [-g] [-h]
#
# Options:
#   -u  Oracle schema / APEX workspace user that owns the app (required, or set
#       APEX_USER in dbfree/.env)
#   -a  APEX application ID
#       (default: auto-detected from the newest matching export in -d)
#   -p  Password for the schema user (default: APEX_PASSWORD/DEFAULT_PASSWORD from .env)
#   -s  Oracle service name (default: SERVICE_NAME from dbfree/.env, else FREEPDB1)
#   -d  Output directory (default: ./apex-exports)
#   -N  Filename prefix for the export (default: app -> app_YYYYMMDD_HHMMSS.sql)
#   -g  Git-commit the exported files LOCALLY after writing (never pushes — see below)
#   -h  Show this help message
#
# Output files (in -d, same YYYYMMDD_HHMMSS timestamp):
#   <prefix>_TIMESTAMP.sql      — APEX application export
#   manifest_TIMESTAMP.txt      — Export metadata and checksums
#
# NOTE ON GIT: -g runs a LOCAL `git commit` only. This script never runs
# `git push` and never will — pushing is left entirely to you.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ── Usage / Help ──────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -u <schema_user> [OPTIONS]

Exports a live APEX application (its Supporting Objects carry the schema) to a
versioned SQL file + manifest. Generic for any APEX app.

Options:
  -u <schema_user>  Oracle schema / APEX workspace user that owns the app
                    (required, or set APEX_USER in dbfree/.env)
  -a <app_id>       APEX application ID
                    (default: auto-detected from the newest export in -d)
  -p <password>     Password for the schema user
                    (default: APEX_PASSWORD from dbfree/.env, else DEFAULT_PASSWORD)
  -s <service>      Oracle service name (default: SERVICE_NAME from dbfree/.env, else FREEPDB1)
  -d <output_dir>   Directory for exported files (default: ./apex-exports)
  -N <prefix>       Filename prefix (default: app -> app_TIMESTAMP.sql)
  -g                Git-commit the exported files LOCALLY (never pushes)
  -h                Show this help and exit

Output files (same YYYYMMDD_HHMMSS timestamp):
  <prefix>_TIMESTAMP.sql    APEX application export
  manifest_TIMESTAMP.txt    Export metadata and checksums

Prerequisites:
  - dbfree stack is running (./run-dbfree.sh completed), or a reachable Oracle service
  - Oracle Instant Client (sqlplus) installed — run ./setup-for-dbfree.sh if not

Examples:
  $(basename "$0") -u MYAPP -a 123
  $(basename "$0") -u TRACKER1 -N sample-app -g
EOF
  exit 0
}

for _arg in "$@"; do
  [[ "$_arg" == "-h" ]] && usage
  [[ "$_arg" == "--" ]] && break
done
unset _arg

source "$SCRIPT_DIR/lib.sh"

DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD)
SERVICE_NAME=$(ini_val SERVICE_NAME); SERVICE_NAME=${SERVICE_NAME:-FREEPDB1}
DB_HOST_PORT=$(ini_val DB_HOST_PORT); DB_HOST_PORT=${DB_HOST_PORT:-15216}
SERVICE_NAME="//localhost:$DB_HOST_PORT/$SERVICE_NAME"
INSTANT_CLIENT="$(resolve_instant_client)"
CFG_APEX_USER=$(ini_val APEX_USER)
CFG_APEX_PASSWORD=$(ini_val APEX_PASSWORD)

# ── Parse options ─────────────────────────────────────────────────────────────
SCHEMA_USER=""
APP_ID=""
OVERRIDE_PASS=""
OUTPUT_DIR="$SCRIPT_DIR/apex-exports"
NAME_PREFIX="app"
GIT_COMMIT=false

while getopts ":u:a:p:s:d:N:gh" opt; do
  case $opt in
    u) SCHEMA_USER="$OPTARG" ;;
    a) APP_ID="$OPTARG" ;;
    p) OVERRIDE_PASS="$OPTARG" ;;
    s) SERVICE_NAME="$OPTARG" ;;
    d) OUTPUT_DIR="$OPTARG" ;;
    N) NAME_PREFIX="$OPTARG" ;;
    g) GIT_COMMIT=true ;;
    h) usage ;;
    :) die "-$OPTARG requires an argument." ;;
    \?) die "Unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

SCHEMA_USER="${SCHEMA_USER:-$CFG_APEX_USER}"
[ -n "$SCHEMA_USER" ] || die "-u <schema_user> is required (or set APEX_USER in dbfree/.env)."
SCHEMA_USER_UPPER="${SCHEMA_USER^^}"
SCHEMA_PASS="${OVERRIDE_PASS:-${CFG_APEX_PASSWORD:-$DEFAULT_PASSWORD}}"

# ── Auto-detect APP_ID from the newest matching export, if not given ──────────
if [ -z "$APP_ID" ]; then
  latest_export=$(ls -t "$OUTPUT_DIR/${NAME_PREFIX}_"*.sql 2>/dev/null | head -1 || true)
  if [ -n "$latest_export" ]; then
    APP_ID=$(apex_detect_app_id "$latest_export")
  fi
  [ -n "$APP_ID" ] || die "-a <app_id> is required — no prior export found in $OUTPUT_DIR to auto-detect from."
  echo "Auto-detected app ID $APP_ID from $(basename "$latest_export")"
fi

# ── Locate sqlplus ────────────────────────────────────────────────────────────
ORACLE_CLIENT_DIR="$HOME/oraclient"
SQLPLUS="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus"

if [ ! -x "$SQLPLUS" ]; then
  if command -v sqlplus &>/dev/null; then
    SQLPLUS="sqlplus"
  else
    die "sqlplus not found at $SQLPLUS and not on PATH. Run ./setup-for-dbfree.sh first (it installs the Instant Client)."
  fi
fi

# dbfree uses plain EZConnect, no wallet/TCPS.
export TNS_ADMIN=""
export LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

# ── Prepare output directory ──────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
APEX_OUT="$OUTPUT_DIR/${NAME_PREFIX}_${TIMESTAMP}.sql"
MANIFEST_OUT="$OUTPUT_DIR/manifest_${TIMESTAMP}.txt"
# Uniquify the staging table per invocation so concurrent exports (different apps/
# users, or two runs racing) never collide on the same table name.
STAGING_TABLE="apex_export_tmp_$$"

TEMP_FILES=()
cleanup() { rm -f "${TEMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup EXIT

# ── Summary ───────────────────────────────────────────────────────────────────
hdr "export-apex-app.sh"
echo "  Schema user  : $SCHEMA_USER_UPPER"
echo "  App ID       : $APP_ID"
echo "  Service      : $SERVICE_NAME"
echo "  Output dir   : $OUTPUT_DIR"
echo "  Git commit   : $GIT_COMMIT (local only — never pushes)"
echo "  SQLPlus      : $SQLPLUS"
echo ""

# ── Step 1: Export APEX application ──────────────────────────────────────────
hdr "Step 1: Exporting APEX application $APP_ID"

# mktemp with a literal suffix after XXXXXX is not portable: macOS/BSD
# mktemp doesn't randomize in that form and returns the same fixed name
# every call, colliding once the file exists — mktemp with no template,
# then rename, works on both.
APEX_EXPORT_SQL=$(mktemp); mv "$APEX_EXPORT_SQL" "$APEX_EXPORT_SQL.sql"; APEX_EXPORT_SQL="$APEX_EXPORT_SQL.sql"
TEMP_FILES+=("$APEX_EXPORT_SQL")

# apex_export.get_application returns apex_t_export_files (a table of CLOBs).
# SET LONG/LONGCHUNKSIZE/LINESIZE control how sqlplus prints the CLOB without truncation.
cat > "$APEX_EXPORT_SQL" << APEX_EOF
SET LONG 2000000000
SET LONGCHUNKSIZE 32767
SET PAGESIZE 0
SET LINESIZE 32767
SET FEEDBACK OFF
SET HEADING OFF
SET TRIMSPOOL ON
SET ECHO OFF
SET VERIFY OFF

-- apex_export.get_application commits internally (WWV_FLOW_SECURITY sets the
-- workspace context). Calling it from inside a SELECT ... FROM TABLE(...) therefore
-- raises ORA-14552 "cannot perform a DDL, commit or rollback inside a query or DML".
-- So: call it from a PL/SQL block (commits are legal there), stash the CLOBs in a
-- staging table, then spool them out with a plain SELECT.
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE $STAGING_TABLE PURGE';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -942 THEN RAISE; END IF;  -- ignore "table does not exist"
END;
/

WHENEVER SQLERROR EXIT SQL.SQLCODE
CREATE TABLE $STAGING_TABLE (seq NUMBER, contents CLOB);

DECLARE
  l_files apex_t_export_files;
BEGIN
  apex_util.set_workspace(p_workspace => '$SCHEMA_USER_UPPER');
  l_files := apex_export.get_application(
    p_application_id       => $APP_ID,
    p_split                => false,
    p_with_date            => true,
    p_with_acl_assignments => true);
  FOR i IN 1 .. l_files.COUNT LOOP
    INSERT INTO $STAGING_TABLE (seq, contents) VALUES (i, l_files(i).contents);
  END LOOP;
  COMMIT;
END;
/

SPOOL $APEX_OUT
SELECT contents FROM $STAGING_TABLE ORDER BY seq;
SPOOL OFF

BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE $STAGING_TABLE PURGE';
EXCEPTION WHEN OTHERS THEN NULL;  -- best-effort cleanup
END;
/
EXIT
APEX_EOF

"$SQLPLUS" -s "$SCHEMA_USER_UPPER/$SCHEMA_PASS@$SERVICE_NAME" "@$APEX_EXPORT_SQL" < /dev/null

if [ ! -f "$APEX_OUT" ] || [ ! -s "$APEX_OUT" ]; then
  die "APEX export failed — $APEX_OUT is missing or empty. Verify the DB is running and app $APP_ID exists in workspace $SCHEMA_USER_UPPER."
fi

APEX_LINES=$(wc -l < "$APEX_OUT")
APEX_KB=$(( $(wc -c < "$APEX_OUT") / 1024 ))
ok "Written: $(basename "$APEX_OUT")  ($APEX_LINES lines, ${APEX_KB} KB)"

# ── Step 2: Write manifest ────────────────────────────────────────────────────
hdr "Step 2: Writing manifest"

{
  echo "APEX Export Manifest"
  echo "====================="
  echo "Timestamp    : $TIMESTAMP"
  echo "Schema user  : $SCHEMA_USER_UPPER"
  echo "App ID       : $APP_ID"
  echo "Service      : $SERVICE_NAME"
  echo "Export file  : $(basename "$APEX_OUT")"
  echo "Note         : DB schema is created by the app's Supporting Objects at import."
  echo ""
  echo "File checksums (sha256):"
  sha256sum "$APEX_OUT" 2>/dev/null || md5sum "$APEX_OUT"
} > "$MANIFEST_OUT"

ok "Written: $(basename "$MANIFEST_OUT")"

# ── Step 3: Optional LOCAL git commit (never pushes) ──────────────────────────
if $GIT_COMMIT; then
  hdr "Step 3: Git commit (local only)"
  pushd "$OUTPUT_DIR" > /dev/null
  git add "$APEX_OUT" "$MANIFEST_OUT"
  git commit -m "Export APEX app $APP_ID ($TIMESTAMP)"
  echo "  Committed locally. Nothing was pushed — push yourself when ready."
  popd > /dev/null
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
ok "Export complete"
echo "  Export file  : $APEX_OUT"
echo "  Manifest     : $MANIFEST_OUT"
echo ""
if ! $GIT_COMMIT; then
  echo "Next steps:"
  echo "  git add $(basename "$OUTPUT_DIR")/ && git commit -m 'Export app $APP_ID after <describe changes>'"
  echo "  ./load-apex-app.sh -f $APEX_OUT      # deploy to another environment"
fi
