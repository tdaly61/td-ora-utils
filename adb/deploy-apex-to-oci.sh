#!/usr/bin/env bash
# deploy-apex-to-oci.sh
# OPTIONAL automated push of an APEX app to an Oracle ADB on OCI: downloads the
# instance wallet via the `oci` CLI, runs the ADMIN grants, then imports the app
# with load-apex-app.sh (which is target-agnostic — it imports into whatever
# wallet/service it is pointed at, local or cloud).
#
# This is the automated counterpart to bundle-apex-for-oci.sh's manual handover
# bundle. It needs the `oci` CLI configured (~/.oci/config) and network access to
# the target ADB; when that isn't available, it prints the manual-bundle command
# and exits — the bundle path always works, this one is a convenience on top of it.
#
# Usage:
#   ./deploy-apex-to-oci.sh -f <export.sql> (--db-ocid <ocid> | --db-name <name> --compartment-id <ocid>)
#                            [-u <schema_user>] [-p <schema_password>]
#                            [--admin-password <pw>] [--llm-host <host>]
#                            [--wallet-password <pw>] [--wallet-dir <dir>]
#                            [--service <alias>] [--profile <name>]
#                            [-v <vector_setup.sql>] [-r STATIC_ID=URL] [-h]
#
# What this script does NOT automate (documented, manual — matches the bundle's
# README): repointing APEX Remote Servers away from a local ollama-proxy URL, and
# any oci_genai-specific worker setup. Do that in APEX Builder after import.

set -euo pipefail

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

usage() {
  cat <<EOF
Usage: $(basename "$0") -f <export.sql> (--db-ocid <ocid> | --db-name <name> --compartment-id <ocid>) [OPTIONS]

Automated push of an APEX app export to an Oracle ADB on OCI: downloads the
wallet via the oci CLI, runs ADMIN grants, imports the app via load-apex-app.sh.

Requires the oci CLI configured (~/.oci/config). If it isn't, this script prints
the manual-bundle command (bundle-apex-for-oci.sh) and exits — that path always
works and needs no OCI CLI setup.

Options:
  -f <file>            APEX export SQL file (required)
  --db-ocid <ocid>      Target Autonomous Database OCID
  --db-name <name>      Target ADB display name (looked up via --compartment-id)
  --compartment-id <id> OCI compartment OCID (required with --db-name)
  -u <schema_user>      Schema owner (default: auto-detected from the export)
  -p <password>         Schema owner password (default: DEFAULT_PASSWORD from .env)
  --admin-password <pw> ADMIN password on the target ADB (default: same as -p)
  --llm-host <host>     Hostname only (no scheme/port) for the outbound LLM ACL
                        (default: skip the ACL grant with a warning)
  --wallet-password <pw> Password to encrypt the downloaded wallet
                        (default: DEFAULT_PASSWORD from .env)
  --wallet-dir <dir>    Where to unzip the wallet (default: ~/oci_adb_wallet/<db-name-or-ocid>)
  --service <alias>     TNS alias suffix (default: high)
  --profile <name>      OCI CLI profile (default: DEFAULT)
  -v <file>              Vector/model setup SQL, passed through to load-apex-app.sh -v
  -r STATIC_ID=URL       Remote-server override, passed through to load-apex-app.sh -r
  --write-connection-info <file>
                        Write the resolved WALLET_DIR/SERVICE_NAME/SCHEMA_USER as
                        plain key=value lines to this file (no passwords) — lets a
                        caller-side wrapper generate its own app-specific worker
                        config without re-deriving the wallet download / DSN lookup
  -h                     Show this help and exit

Example:
  $(basename "$0") -f apex-exports/app_20260719.sql \\
      --db-ocid ocid1.autonomousdatabase.oc1..xxxx --llm-host api.x.ai
EOF
  exit 0
}

for _arg in "$@"; do
  [[ "$_arg" == "-h" ]] && usage
  [[ "$_arg" == "--" ]] && break
done
unset _arg

CONFIG_FILE="$RUN_DIR/.env"; [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$RUN_DIR/config.ini"
[ -f "$CONFIG_FILE" ] || { echo "ERROR: .env (or config.ini) not found in $RUN_DIR"; exit 1; }

# shellcheck source=common.sh
source "$RUN_DIR/common.sh"
detect_platform

DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD)
INSTANT_CLIENT="$(resolve_instant_client)"

# ── Guard: oci CLI must be configured, or fall back to the manual bundle path ──
if ! command -v oci &>/dev/null; then
  echo "The 'oci' CLI is not installed — automated push is unavailable."
  echo ""
  echo "Use the manual handover bundle instead (works with no OCI CLI setup):"
  echo "  ./bundle-apex-for-oci.sh -f <export.sql>"
  exit 1
fi
if [ ! -f "$HOME/.oci/config" ]; then
  echo "~/.oci/config not found — the oci CLI is not configured for this host."
  echo ""
  echo "Use the manual handover bundle instead (works with no OCI CLI setup):"
  echo "  ./bundle-apex-for-oci.sh -f <export.sql>"
  exit 1
fi

# ── Parse options ─────────────────────────────────────────────────────────────
APEX_SQL=""
DB_OCID=""
DB_NAME=""
COMPARTMENT_ID=""
SCHEMA_USER=""
SCHEMA_PASS=""
ADMIN_PASSWORD=""
LLM_HOST=""
WALLET_PASSWORD=""
WALLET_DIR=""
SERVICE_ALIAS="high"
OCI_PROFILE="DEFAULT"
VECTOR_SQL=""
CONN_INFO_FILE=""
declare -a RS_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    -f) APEX_SQL="$2"; shift 2 ;;
    --db-ocid) DB_OCID="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --compartment-id) COMPARTMENT_ID="$2"; shift 2 ;;
    -u) SCHEMA_USER="$2"; shift 2 ;;
    -p) SCHEMA_PASS="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --llm-host) LLM_HOST="$2"; shift 2 ;;
    --wallet-password) WALLET_PASSWORD="$2"; shift 2 ;;
    --wallet-dir) WALLET_DIR="$2"; shift 2 ;;
    --service) SERVICE_ALIAS="$2"; shift 2 ;;
    --profile) OCI_PROFILE="$2"; shift 2 ;;
    -v) VECTOR_SQL="$2"; shift 2 ;;
    -r) RS_ARGS+=("-r" "$2"); shift 2 ;;
    --write-connection-info) CONN_INFO_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown option $1"; exit 1 ;;
  esac
done

[ -n "$APEX_SQL" ] || { echo "ERROR: -f <export.sql> is required."; exit 1; }
[ -f "$APEX_SQL" ] || { echo "ERROR: APEX export file not found: $APEX_SQL"; exit 1; }
if [ -z "$DB_OCID" ] && { [ -z "$DB_NAME" ] || [ -z "$COMPARTMENT_ID" ]; }; then
  echo "ERROR: pass --db-ocid, or both --db-name and --compartment-id."
  exit 1
fi

SCHEMA_USER="${SCHEMA_USER:-$(apex_detect_owner "$APEX_SQL")}"
[ -n "$SCHEMA_USER" ] || { echo "ERROR: could not auto-detect schema owner — pass -u."; exit 1; }
SCHEMA_USER="${SCHEMA_USER^^}"
SCHEMA_PASS="${SCHEMA_PASS:-$DEFAULT_PASSWORD}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$SCHEMA_PASS}"
WALLET_PASSWORD="${WALLET_PASSWORD:-$DEFAULT_PASSWORD}"

# ── Resolve the target ADB OCID ────────────────────────────────────────────────
if [ -z "$DB_OCID" ]; then
  echo "Looking up ADB OCID for '$DB_NAME' in compartment $COMPARTMENT_ID..."
  DB_OCID=$(oci db autonomous-database list \
              --compartment-id "$COMPARTMENT_ID" \
              --display-name "$DB_NAME" \
              --profile "$OCI_PROFILE" \
              --query 'data[0].id' --raw-output 2>/dev/null || true)
  [ -n "$DB_OCID" ] && [ "$DB_OCID" != "null" ] \
    || { echo "ERROR: no ADB named '$DB_NAME' found in that compartment."; exit 1; }
fi
WALLET_DIR="${WALLET_DIR:-$HOME/oci_adb_wallet/${DB_NAME:-$DB_OCID}}"

echo ""
echo "=== deploy-apex-to-oci.sh ==="
echo "  APEX export  : $(basename "$APEX_SQL")"
echo "  Target ADB   : $DB_OCID"
echo "  Schema user  : $SCHEMA_USER"
echo "  Wallet dir   : $WALLET_DIR"
echo ""

# ── Step 1: Download and unzip the wallet ──────────────────────────────────────
echo "=== Step 1: Downloading instance wallet ==="
mkdir -p "$WALLET_DIR"
WALLET_ZIP=$(mktemp /tmp/oci_wallet_XXXXXX.zip)
trap 'rm -f "$WALLET_ZIP"' EXIT

oci db autonomous-database generate-wallet \
  --autonomous-database-id "$DB_OCID" \
  --file "$WALLET_ZIP" \
  --password "$WALLET_PASSWORD" \
  --profile "$OCI_PROFILE"

unzip -o -q "$WALLET_ZIP" -d "$WALLET_DIR"
echo "  Wallet unzipped to $WALLET_DIR"

if ! grep -qi "^[[:space:]]*[a-zA-Z0-9_]*_${SERVICE_ALIAS}[[:space:]]*=" "$WALLET_DIR/tnsnames.ora" 2>/dev/null; then
  echo "WARNING: no '_${SERVICE_ALIAS}' alias found in tnsnames.ora — check --service."
  echo "Available aliases:"
  grep -oE '^[a-zA-Z0-9_]+' "$WALLET_DIR/tnsnames.ora" 2>/dev/null | sort -u | sed 's/^/  /'
fi
SERVICE_NAME=$(grep -oE '^[a-zA-Z0-9_]+' "$WALLET_DIR/tnsnames.ora" 2>/dev/null \
                 | grep -i "_${SERVICE_ALIAS}$" | head -1)
[ -n "$SERVICE_NAME" ] || { echo "ERROR: could not resolve a '_${SERVICE_ALIAS}' service name from the wallet."; exit 1; }
echo "  Service      : $SERVICE_NAME"

# ── Step 2: Run ADMIN grants ───────────────────────────────────────────────────
echo ""
echo "=== Step 2: Running ADMIN grants ==="
if [ -z "$LLM_HOST" ]; then
  echo "  WARNING: --llm-host not given — skipping the outbound LLM network ACL grant."
  echo "           In-app AI / outbound HTTP calls will fail until you grant it manually"
  echo "           (see sql-scripts/oci-admin-grants.sql.tpl)."
fi
ADMIN_GRANTS_SQL=$(mktemp /tmp/oci_admin_grants_XXXXXX.sql)
trap 'rm -f "$WALLET_ZIP" "$ADMIN_GRANTS_SQL"' EXIT
sed -e "s/__SCHEMA__/$SCHEMA_USER/g" \
    -e "s/__LLM_HOST__/${LLM_HOST:-CHANGE_ME_LLM_HOST}/g" \
    "$RUN_DIR/sql-scripts/oci-admin-grants.sql.tpl" > "$ADMIN_GRANTS_SQL"

ORACLE_CLIENT_DIR="$HOME/oraclient"
SQLPLUS="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus"
[ -x "$SQLPLUS" ] || SQLPLUS="sqlplus"
command -v "$SQLPLUS" &>/dev/null || [ -x "$SQLPLUS" ] \
  || { echo "ERROR: sqlplus not found. Run sudo ./setup-for-adb-26ai.sh first."; exit 1; }

export TNS_ADMIN="$WALLET_DIR"
export LD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

echo "  NOTE: this assumes the schema user already exists on the target ADB"
echo "        (create it in Database Actions first if this is a fresh instance —"
echo "        see the CREATE USER comment in sql-scripts/oci-admin-grants.sql.tpl)."
"$SQLPLUS" -s "admin/$ADMIN_PASSWORD@$SERVICE_NAME" "@$ADMIN_GRANTS_SQL"
echo "  ADMIN grants applied."

# ── Step 3: Import via load-apex-app.sh (target-agnostic — TNS_ADMIN already set) ──
echo ""
echo "=== Step 3: Importing APEX app via load-apex-app.sh ==="
declare -a LOAD_ARGS=(-f "$APEX_SQL" -u "$SCHEMA_USER" -p "$SCHEMA_PASS" -s "$SERVICE_NAME")
[ -n "$VECTOR_SQL" ] && LOAD_ARGS+=(-v "$VECTOR_SQL")
LOAD_ARGS+=("${RS_ARGS[@]+"${RS_ARGS[@]}"}")

"$RUN_DIR/load-apex-app.sh" "${LOAD_ARGS[@]}"

# ── Optional: expose what we resolved for a caller-side wrapper ───────────────
if [ -n "$CONN_INFO_FILE" ]; then
  ( umask 077; cat > "$CONN_INFO_FILE" <<EOF
WALLET_DIR=$WALLET_DIR
SERVICE_NAME=$SERVICE_NAME
SCHEMA_USER=$SCHEMA_USER
EOF
  )
  chmod 600 "$CONN_INFO_FILE"
  echo ""
  echo "  Wrote connection info -> $CONN_INFO_FILE"
fi

echo ""
echo "=== Deploy to OCI complete ==="
echo "  Wallet   : $WALLET_DIR  (TNS_ADMIN for future sqlplus sessions)"
echo "  Service  : $SERVICE_NAME"
echo ""
echo "  MANUAL step still required: repoint any APEX Remote Servers that point at"
echo "  a local ollama-proxy URL to your real LLM endpoint (APEX Builder ->"
echo "  Workspace Utilities -> Remote Servers) — this script does not know your"
echo "  app's remote-server static IDs."
