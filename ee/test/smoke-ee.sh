#!/usr/bin/env bash
# smoke-ee.sh — post-deploy verification for the ee/ stack. Checks:
#   1. sqlplus connectivity as the compat ADMIN user (plain EZConnect)
#   2. v$pgastat / v$resource_limit baseline (logged, not pass/failed —
#      see the ee POC plan's Validation section for what to do with these
#      numbers once real load testing happens)
#   3. ORDS responds on /ords/
#   4. APEX serves a styled login page (not a raw/unstyled error page)
#
# Exits non-zero on the first failed check, naming it. Safe to run repeatedly.
#
# Usage: ./test/smoke-ee.sh

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/../lib.sh"

ORACLE_PDB="$(ini_val ORACLE_PDB)"; ORACLE_PDB="${ORACLE_PDB:-FREEPDB1}"
APEX_PORT="$(ini_val APEX_PORT)"; APEX_PORT="${APEX_PORT:-8080}"
DB_HOST_PORT="$(ini_val DB_HOST_PORT)"; DB_HOST_PORT="${DB_HOST_PORT:-1523}"
ADMIN_COMPAT_PASSWORD="$(ini_val ADMIN_COMPAT_PASSWORD)"
[ -z "$ADMIN_COMPAT_PASSWORD" ] && ADMIN_COMPAT_PASSWORD="$(adb_val DEFAULT_PASSWORD)"
EZCONNECT="//localhost:$DB_HOST_PORT/$ORACLE_PDB"

FAIL=0
check() {
    local name="$1"; shift
    if "$@"; then
        ok "$name"
    else
        fail "$name"
        FAIL=1
    fi
}

hdr "smoke-ee.sh"

# ── 1. sqlplus connectivity ────────────────────────────────────────────────
CONN_SQL="$(mktemp /tmp/ee_smoke_conn_XXXXXX.sql)"
trap 'rm -f "$CONN_SQL"' EXIT
cat > "$CONN_SQL" <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF
SELECT 'CONNECT_OK' FROM dual;
exit;
SQL
CONN_OUT="$(run_sql_ezconnect "ADMIN" "$ADMIN_COMPAT_PASSWORD" "$EZCONNECT" "$CONN_SQL" 2>&1 || true)"
if echo "$CONN_OUT" | grep -q "CONNECT_OK"; then
    ok "sqlplus connectivity as ADMIN via $EZCONNECT"
else
    fail "sqlplus connectivity as ADMIN via $EZCONNECT"
    echo "$CONN_OUT" | sed 's/^/    /'
    FAIL=1
fi

# ── 2. PGA/session baseline (informational, logged for the Validation phase) ─
hdr "PGA / session baseline"
BASELINE_SQL="$(mktemp /tmp/ee_smoke_pga_XXXXXX.sql)"
trap 'rm -f "$BASELINE_SQL"' EXIT
cat > "$BASELINE_SQL" <<'SQL'
SET PAGESIZE 100 LINESIZE 200 FEEDBACK OFF
SHOW PARAMETER pga_aggregate_limit
SHOW PARAMETER pga_aggregate_target
SELECT name, value FROM v$pgastat WHERE name IN
  ('aggregate PGA target parameter','total PGA inuse','total PGA allocated','maximum PGA allocated');
SELECT resource_name, current_utilization, max_utilization, limit_value
  FROM v$resource_limit WHERE resource_name IN ('processes','sessions','pga_aggregate_limit');
exit;
SQL
run_sql_ezconnect "ADMIN" "$ADMIN_COMPAT_PASSWORD" "$EZCONNECT" "$BASELINE_SQL" 2>&1 | sed 's/^/    /' || true

# ── 3. ORDS responds ───────────────────────────────────────────────────────
check "ORDS responds on /ords/" curl -sf -o /dev/null "http://localhost:$APEX_PORT/ords/"

# ── 4. APEX login page is styled ───────────────────────────────────────────
# /ords/apex (no trailing slash) 302s to a workspace-sign-in URL that sets a
# session cookie and immediately redirects again to a NEW session if that
# cookie isn't retained — a cookie jar is required or curl just bounces
# between sign-in URLs until it hits its redirect limit and gives up.
# (/ords/apex/ WITH a trailing slash is a different, unmapped path and 404s —
# not the one to check.)
APEX_COOKIEJAR="$(mktemp /tmp/ee_smoke_apex_cookies_XXXXXX.txt)"
trap 'rm -f "$APEX_COOKIEJAR"' EXIT
APEX_BODY="$(curl -sL -c "$APEX_COOKIEJAR" -b "$APEX_COOKIEJAR" "http://localhost:$APEX_PORT/ords/apex" 2>/dev/null || true)"
if echo "$APEX_BODY" | grep -qi "Oracle APEX"; then
    ok "APEX serves a real sign-in page at /ords/apex"
else
    fail "APEX did not serve an APEX-looking page at /ords/apex (got: $(echo "$APEX_BODY" | head -c 200))"
    FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    ok "All smoke checks passed."
else
    fail "One or more smoke checks failed — see above."
fi
exit "$FAIL"
