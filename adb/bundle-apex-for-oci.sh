#!/usr/bin/env bash
# bundle-apex-for-oci.sh
# Packages an APEX app export + optional post-import SQL + optional payload
# (e.g. worker scripts) into a self-contained tarball a colleague can deploy to
# an Oracle ADB running in OCI — generic for any APEX app.
#
# Why a manual-handover bundle rather than an automated push: OCI ADB has no
# ollama-proxy-style local network, no host.docker.internal, and no local
# sqlplus/ADMIN access to the container. So the bundle ships:
#   - a numbered set of SQL scripts to run in SQL Developer / Database Actions
#   - the APEX app export, imported through APEX Builder
#   - an optional payload directory, run from any host that can reach the ADB
#
# Usage:
#   ./bundle-apex-for-oci.sh -f <export.sql> [OPTIONS]
#
# Options:
#   -f <file>            APEX export SQL file (default: newest ./apex-exports/*.sql)
#   -o <dir>              Output directory for the bundle (default: ./dist)
#   --admin-sql <file>    ADMIN grants SQL -> sql/01_admin_grants.sql
#                         (default: generated from sql-scripts/oci-admin-grants.sql.tpl
#                         using the schema auto-detected from the export)
#   --post-sql <file>     Post-import SQL to run as the schema owner, in order given
#                         (repeatable) -> sql/02_*, sql/03_*, ...
#   --onnx-model <name>   Render sql-scripts/load-onnx-model.sql.tpl for this model
#                         name -> the next numbered sql/ script (before --post-sql)
#   --onnx-url <url>      URL for --onnx-model (default: ONNX_MODEL_URL from .env —
#                         Oracle's public pre-authenticated object-storage URL works
#                         from OCI with no credential). Optional: if omitted and no
#                         .env default exists, the generated script is left with
#                         DEFINE ONNX_URL = CHANGE_ME_ONNX_URL for the deployer to
#                         edit at deploy time (same deferred pattern as LLM_HOST in
#                         sql/01_admin_grants.sql) — check-prereqs.sh already flags
#                         any unedited CHANGE_ME placeholder.
#   --payload-dir <dir>   Directory copied verbatim into payload/ (e.g. worker
#                         scripts + their own requirements/README)
#   --readme-fragment <f> Markdown appended to the generic README-OCI.md
#   --check-prereqs <f>   Override the generic check-prereqs.sh with this file
#   -h                    Show this help and exit
#
# Bundle contents:
#   README-OCI.md          Step-by-step deployment guide
#   sql/01_admin_grants.sql  Run as ADMIN: grants + network ACL
#   apex/<export>.sql      Import in APEX Builder (Supporting Objects CHECKED)
#   sql/0N_*.sql            Post-import steps, run as the schema owner, in order
#   payload/                Optional — whatever the app supplied via --payload-dir
#   check-prereqs.sh        Validates the bundle before anything long-running runs
#   MANIFEST.txt            Contents, checksums, source commit (read-only; no git writes)
#
# NOTE ON GIT: this script only READS the current commit (`git rev-parse`) for the
# manifest. It never runs `git commit` or `git push`.

set -euo pipefail

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

usage() {
  cat <<EOF
Usage: $(basename "$0") -f <export.sql> [OPTIONS]

Packages an APEX app export + optional SQL/payload into a self-contained
tarball for manual handover to an Oracle ADB on OCI. Generic for any app.

Options:
  -f <file>            APEX export SQL file (default: newest ./apex-exports/*.sql)
  -o <dir>              Output directory (default: ./dist)
  --admin-sql <file>    -> sql/01_admin_grants.sql (default: generated, generic)
  --post-sql <file>     -> sql/0N_*.sql, in order given (repeatable)
  --onnx-model <name>   Render the generic ONNX loader for this model name
  --onnx-url <url>      URL for --onnx-model (default: .env ONNX_MODEL_URL,
                        else deferred to a deploy-time DEFINE — see below)
  --payload-dir <dir>   Copied verbatim into payload/
  --readme-fragment <f> Appended to the generic README-OCI.md
  --check-prereqs <f>   Override the generic check-prereqs.sh
  -h                    Show this help and exit

Examples:
  $(basename "$0") -f apex-exports/app_20260719.sql
  $(basename "$0") -f app.sql --onnx-model MY_EMBED_MODEL \\
      --post-sql app_users.sql --payload-dir ./workers
EOF
  exit 0
}

for _arg in "$@"; do
  [[ "$_arg" == "-h" ]] && usage
  [[ "$_arg" == "--" ]] && break
done
unset _arg

CONFIG_FILE="$RUN_DIR/.env"; [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$RUN_DIR/config.ini"

# shellcheck source=common.sh
source "$RUN_DIR/common.sh"
detect_platform
[ -f "$CONFIG_FILE" ] && ONNX_MODEL_URL_DEFAULT="$(ini_val ONNX_MODEL_URL 2>/dev/null || true)"

# ── Parse options ─────────────────────────────────────────────────────────────
APEX_SQL=""
OUT_DIR="$RUN_DIR/dist"
ADMIN_SQL=""
POST_SQL=()
ONNX_MODEL=""
ONNX_URL="${ONNX_MODEL_URL_DEFAULT:-}"
PAYLOAD_DIR=""
README_FRAGMENT=""
CHECK_PREREQS_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -f) APEX_SQL="$2"; shift 2 ;;
    -o) OUT_DIR="$2"; shift 2 ;;
    --admin-sql) ADMIN_SQL="$2"; shift 2 ;;
    --post-sql) POST_SQL+=("$2"); shift 2 ;;
    --onnx-model) ONNX_MODEL="$2"; shift 2 ;;
    --onnx-url) ONNX_URL="$2"; shift 2 ;;
    --payload-dir) PAYLOAD_DIR="$2"; shift 2 ;;
    --readme-fragment) README_FRAGMENT="$2"; shift 2 ;;
    --check-prereqs) CHECK_PREREQS_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown option $1"; exit 1 ;;
  esac
done

echo ""
echo "=== bundle-apex-for-oci.sh ==="

# ── Resolve the APEX export ───────────────────────────────────────────────────
if [ -z "$APEX_SQL" ]; then
  APEX_SQL=$(ls -t "$RUN_DIR/apex-exports/"*.sql 2>/dev/null | grep -v '^manifest_' | head -1 || true)
fi
if [ -z "$APEX_SQL" ] || [ ! -f "$APEX_SQL" ]; then
  echo "ERROR: No APEX export given/found. Pass -f <file>, or run ./export-apex-app.sh first."
  exit 1
fi
APEX_SQL="$(realpath "$APEX_SQL")"

APP_ID=$(apex_detect_app_id "$APEX_SQL")
SCHEMA_USER=$(apex_detect_owner "$APEX_SQL")
if [ -z "$SCHEMA_USER" ]; then
  echo "ERROR: Could not auto-detect the schema owner (p_default_owner) from $APEX_SQL"
  exit 1
fi
SCHEMA_USER="${SCHEMA_USER^^}"
APP_ID="${APP_ID:-unknown}"

EXPORT_BASENAME="$(basename "$APEX_SQL")"
BUNDLE_TS="$(date +%Y%m%d_%H%M%S)"

echo "  APEX export  : $EXPORT_BASENAME"
echo "  App ID       : $APP_ID"
echo "  Schema user  : $SCHEMA_USER"
echo "  Schema       : created by the app's Supporting Objects at import"

# ── Stage the bundle ──────────────────────────────────────────────────────────
BUNDLE_NAME="apex-oci-${SCHEMA_USER,,}-${BUNDLE_TS}"
STAGE="$OUT_DIR/$BUNDLE_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{sql,apex}

cp "$APEX_SQL" "$STAGE/apex/"

if [ -n "$PAYLOAD_DIR" ]; then
  [ -d "$PAYLOAD_DIR" ] || { echo "ERROR: --payload-dir not found: $PAYLOAD_DIR"; exit 1; }
  mkdir -p "$STAGE/payload"
  cp -r "$PAYLOAD_DIR"/. "$STAGE/payload/"
fi

# ── sql/01_admin_grants.sql ───────────────────────────────────────────────────
if [ -n "$ADMIN_SQL" ]; then
  [ -f "$ADMIN_SQL" ] || { echo "ERROR: --admin-sql not found: $ADMIN_SQL"; exit 1; }
  cp "$ADMIN_SQL" "$STAGE/sql/01_admin_grants.sql"
else
  sed -e "s/__SCHEMA__/$SCHEMA_USER/g" \
      -e "s/__LLM_HOST__/CHANGE_ME_LLM_HOST/g" \
      "$RUN_DIR/sql-scripts/oci-admin-grants.sql.tpl" > "$STAGE/sql/01_admin_grants.sql"
  echo "  sql/01_admin_grants.sql : generated (generic template, schema=$SCHEMA_USER)"
fi

# ── Remaining numbered SQL: ONNX loader (if requested), then --post-sql in order ──
_next_num=2
if [ -n "$ONNX_MODEL" ]; then
  _num=$(printf '%02d' "$_next_num")
  sed -e "s/__MODEL_NAME__/$ONNX_MODEL/g" \
      -e "s|__ONNX_URL__|${ONNX_URL:-CHANGE_ME_ONNX_URL}|g" \
      "$RUN_DIR/sql-scripts/load-onnx-model.sql.tpl" > "$STAGE/sql/${_num}_load_onnx_model.sql"
  if [ -z "$ONNX_URL" ]; then
    echo "  sql/${_num}_load_onnx_model.sql : generated (model=$ONNX_MODEL, URL deferred — edit DEFINE before running)"
  else
    echo "  sql/${_num}_load_onnx_model.sql : generated (model=$ONNX_MODEL)"
  fi
  _next_num=$((_next_num + 1))
fi

for _f in "${POST_SQL[@]+"${POST_SQL[@]}"}"; do
  [ -f "$_f" ] || { echo "ERROR: --post-sql not found: $_f"; exit 1; }
  _num=$(printf '%02d' "$_next_num")
  _base="$(basename "$_f")"
  cp "$_f" "$STAGE/sql/${_num}_${_base}"
  echo "  sql/${_num}_${_base}"
  _next_num=$((_next_num + 1))
done

# ── check-prereqs.sh ───────────────────────────────────────────────────────────
if [ -n "$CHECK_PREREQS_OVERRIDE" ]; then
  [ -f "$CHECK_PREREQS_OVERRIDE" ] || { echo "ERROR: --check-prereqs not found: $CHECK_PREREQS_OVERRIDE"; exit 1; }
  cp "$CHECK_PREREQS_OVERRIDE" "$STAGE/check-prereqs.sh"
else
  # Generic default: scans for leftover CHANGE_ME placeholders anywhere in the
  # bundle, and — if a wallet was unzipped alongside it — checks tnsnames.ora is
  # present. Apps with richer prerequisites (LLM reachability, model tags, etc.)
  # should pass --check-prereqs with their own script; this default stays
  # deliberately generic (no app/provider-specific knowledge belongs here).
  cat > "$STAGE/check-prereqs.sh" <<'CHECK_EOF'
#!/usr/bin/env bash
# check-prereqs.sh — validate this bundle's config BEFORE running anything long-running.
# Run from the bundle root: ./check-prereqs.sh [wallet_dir]
set -uo pipefail

fail=0
ok()   { printf '  \033[0;32m✓\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[0;31m✗\033[0m  %s\n' "$*"; fail=1; }
warn() { printf '  \033[0;33m!\033[0m  %s\n' "$*"; }

echo ""
echo "=== APEX OCI bundle prerequisites ==="

_hits=$(grep -rl 'CHANGE_ME' . 2>/dev/null | grep -v '^\./check-prereqs.sh$' || true)
if [ -n "$_hits" ]; then
  bad "Unedited CHANGE_ME placeholders found:"
  printf '%s\n' "$_hits" | sed 's/^/       /'
else
  ok "No unedited CHANGE_ME placeholders found"
fi

WALLET_DIR="${1:-}"
if [ -n "$WALLET_DIR" ]; then
  WALLET_EXP="${WALLET_DIR/#\~/$HOME}"
  if [ -f "$WALLET_EXP/tnsnames.ora" ]; then
    ok "wallet found at $WALLET_EXP"
  else
    bad "wallet not found at $WALLET_EXP (expected tnsnames.ora inside)"
    echo "       Download the wallet from the OCI ADB console and unzip it there."
  fi
else
  warn "no wallet dir passed — re-run as: ./check-prereqs.sh <wallet_dir> to check it"
fi

if [ -d payload ]; then
  ok "payload/ present — see its own README/requirements for further checks"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  printf '  \033[0;32mAll checks passed.\033[0m\n\n'
else
  printf '  \033[0;31mFix the items marked \xe2\x9c\x97 above before proceeding.\033[0m\n\n'
  exit 1
fi
CHECK_EOF
fi
chmod +x "$STAGE/check-prereqs.sh"

# ── README-OCI.md ─────────────────────────────────────────────────────────────
{
  cat <<README_EOF
# Deploy to Oracle ADB on OCI

APEX app **${APP_ID}**, schema **${SCHEMA_USER}**, bundled ${BUNDLE_TS}.

## Deployment steps

### 1. Create the schema owner and grant it (as ADMIN)

Create the user in **Database Actions → Database Users** (or with \`CREATE USER\`),
then in **Database Actions → SQL**, connected as \`ADMIN\`, edit the \`DEFINE\`
lines at the top of \`sql/01_admin_grants.sql\` and run it.

### 2. Import the APEX app — this creates the schema

In **APEX Builder → App Builder → Import**, upload \`apex/${EXPORT_BASENAME}\`.

> **Keep "Install Supporting Objects" CHECKED.**
> The app's Supporting Objects are the source of the schema — they create all
> tables, views, sequences and PL/SQL. Installing them is what builds the
> database for the app.

Set the parsing schema to \`${SCHEMA_USER}\` during import. After install, verify
there are no invalid objects:

\`\`\`sql
SELECT object_name, object_type FROM user_objects WHERE status = 'INVALID';  -- expect no rows
\`\`\`

### 3. Run the remaining numbered SQL (as ${SCHEMA_USER})

Run each \`sql/0N_*.sql\` file in order, connected as \`${SCHEMA_USER}\`. Edit any
unfilled \`DEFINE\` placeholder values at the top of each file first.
README_EOF

  if [ -d "$STAGE/payload" ]; then
    cat <<'README_EOF'

### 4. Run the payload

`payload/` can run anywhere with network access to the ADB (and to any external
service it calls) — an OCI compute VM, or your own machine. See its own
README/requirements for setup and run instructions.

Before starting anything long-running:

```bash
./check-prereqs.sh <wallet_dir>
```
README_EOF
  fi

  if [ -n "$README_FRAGMENT" ]; then
    [ -f "$README_FRAGMENT" ] || { echo "ERROR: --readme-fragment not found: $README_FRAGMENT" >&2; exit 1; }
    echo ""
    cat "$README_FRAGMENT"
  fi
} > "$STAGE/README-OCI.md"

# ── Secret scan ─────────────────────────────────────────────────────────────
# Refuses to package the bundle if a literal (non-substitution) password/credential
# value, or a real .env/.credentials file, made it into the staged tree.
echo ""
echo "  Scanning staged bundle for secrets..."
_scan_hits=$(grep -rniE \
  "dbms_cloud\.create_credential|(p_web_password|wallet_password|password)[[:space:]]*(=>|=)[[:space:]]*'[^&]" \
  "$STAGE" --exclude='*.env.sample' --exclude='check-prereqs.sh' 2>/dev/null || true)
if [ -n "$_scan_hits" ]; then
  echo "ERROR: possible credential found in the staged bundle — refusing to package."
  printf '%s\n' "$_scan_hits" | head
  exit 1
fi
if find "$STAGE" \( -name '.env' -o -name '.credentials' \) | grep -q .; then
  echo "ERROR: a real .env/.credentials file was staged — refusing to package."
  exit 1
fi
echo "  No secrets found."

# ── Manifest (reads git state only — never commits or pushes) ────────────────
{
  echo "APEX OCI Deployment Bundle"
  echo "=========================="
  echo "Built        : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "APEX app ID  : $APP_ID"
  echo "Schema user  : $SCHEMA_USER"
  echo "Source commit: $(git -C "$RUN_DIR" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
  echo "Schema       : created by the app's Supporting Objects at import"
  echo ""
  echo "Deploy order : README-OCI.md -> sql/01 -> APEX import (Supporting Objects ON) -> sql/0N..."
  echo ""
  echo "Contents (sha256):"
  (cd "$STAGE" && find . -type f ! -name MANIFEST.txt -print0 | sort -z \
     | xargs -0 sha256sum | sed 's|  \./|  |')
} > "$STAGE/MANIFEST.txt"

# ── Package ───────────────────────────────────────────────────────────────────
TARBALL="$OUT_DIR/${BUNDLE_NAME}.tar.gz"
rm -f "$TARBALL"
tar -czf "$TARBALL" -C "$OUT_DIR" "$BUNDLE_NAME"

echo ""
echo "=== Bundle complete ==="
echo "  Tarball : $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo "  Staged  : $STAGE"
echo ""
echo "  Hand the tarball to whoever deploys it. They start with README-OCI.md."
echo "  (This script never runs git commit/push — nothing here was published.)"
echo ""
