#!/usr/bin/env bash
# smoke-adb.sh
# Deterministic, tokenless verification harness for the adb toolkit. Asserts —
# rather than eyeballs — that the local Oracle 26ai + APEX + Ollama stack is up
# and reachable, and optionally that a given APEX app imports cleanly. Generic:
# knows nothing about any particular application.
#
# Exit code 0 = all checks passed, non-zero = at least one failed. Output is
# TAP-style (ok/not ok N - description) by default, or --json for a JSON summary.
# Designed to be run directly, from CI, on a schedule, or wrapped by
# `claude /loop` for self-healing dev iteration (see adb/README.md).
#
# Usage:
#   ./smoke-adb.sh [--from-scratch] [--also-wipe-docker] [--app <export.sql>]
#                  [--json] [-h]
#
# Options:
#   --from-scratch     Tear down and rebuild first: run-adb-26ai.sh -c, then
#                       setup-for-adb-26ai.sh, then run-adb-26ai.sh, before
#                       asserting. Destructive — asks for confirmation unless
#                       stdin is non-interactive AND --yes is also given.
#   --yes               Skip the --from-scratch confirmation prompt (for CI).
#   --also-wipe-docker  With --from-scratch, also run setup-for-adb-26ai.sh -c
#                       first. WARNING: on Linux this runs
#                       `docker system prune -a -f --volumes` and uninstalls
#                       Docker itself from the host — not scoped to this repo.
#                       Off by default even with --from-scratch. Always confirmed.
#   --app <file>        After the infra checks pass, import this APEX export via
#                       load-apex-app.sh and assert it registered with no
#                       INVALID objects for its schema.
#   --json               Emit a JSON summary instead of TAP text.
#   -h                    Show this help and exit.
#
# NOTE ON GIT: this script makes no git calls at all.

set -uo pipefail

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--from-scratch] [--also-wipe-docker] [--app <export.sql>] [--json] [-h]

Deterministic smoke test for the adb toolkit: asserts the local Oracle 26ai +
APEX + Ollama stack is up and reachable. Generic — no app-specific knowledge.

Options:
  --from-scratch      Tear down (run-adb-26ai.sh -c) and rebuild (setup + run)
                      before asserting. Destructive — confirms unless --yes.
  --yes                Skip the --from-scratch confirmation prompt.
  --also-wipe-docker   With --from-scratch, also run setup-for-adb-26ai.sh -c
                      (WARNING: wipes ALL local Docker state, not just this
                      repo's — see its own warning). Off by default. Confirmed.
  --app <file>         Import this APEX export and assert it registered cleanly.
  --json               Emit a JSON summary instead of TAP text.
  -h                    Show this help and exit.

Examples:
  ./smoke-adb.sh                              # assert current state
  ./smoke-adb.sh --from-scratch --yes          # full clean rebuild + assert (CI)
  ./smoke-adb.sh --app apex-exports/app.sql    # also verify an app imports
EOF
  exit 0
}

FROM_SCRATCH=false
ALSO_WIPE_DOCKER=false
ASSUME_YES=false
APP_FILE=""
JSON_OUT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --from-scratch) FROM_SCRATCH=true; shift ;;
    --also-wipe-docker) ALSO_WIPE_DOCKER=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --app) APP_FILE="$2"; shift 2 ;;
    --json) JSON_OUT=true; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: Unknown option $1" >&2; exit 1 ;;
  esac
done

CONFIG_FILE="$RUN_DIR/.env"; [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$RUN_DIR/config.ini"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: .env (or config.ini) not found in $RUN_DIR" >&2
  exit 1
fi

# shellcheck source=../common.sh
source "$RUN_DIR/common.sh"
detect_platform

DEFAULT_PASSWORD=$(ini_val DEFAULT_PASSWORD | tr -d '\n\r')
CONTAINER_NAME=$(ini_val CONTAINER_NAME); CONTAINER_NAME="${CONTAINER_NAME:-adb-free}"
SERVICE_NAME=$(ini_val SERVICE_NAME); SERVICE_NAME="${SERVICE_NAME:-myatp_high}"
APEX_PORT=$(ini_val APEX_PORT); APEX_PORT="${APEX_PORT:-8443}"
INSTANT_CLIENT="$(resolve_instant_client)"
PROXY_CONTAINER="ollama-proxy"

# ── Result tracking ─────────────────────────────────────────────────────────
_n=0
declare -a _RESULTS=()   # "ok|description" or "not ok|description|diagnostic"

check() {
  local desc="$1" ok="$2" diag="${3:-}"
  _n=$((_n + 1))
  if [ "$ok" = "true" ]; then
    _RESULTS+=("ok|$desc|")
    $JSON_OUT || echo "ok $_n - $desc"
  else
    _RESULTS+=("not ok|$desc|$diag")
    $JSON_OUT || { echo "not ok $_n - $desc"; [ -n "$diag" ] && echo "  # $diag"; }
  fi
}

sql_scalar() {
  # Runs a single-value query via host sqlplus as admin. Prints the trimmed result.
  local query="$1"
  TNS_ADMIN="$HOME/auth/tls_wallet" \
  LD_LIBRARY_PATH="$HOME/oraclient/$INSTANT_CLIENT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  DYLD_LIBRARY_PATH="$HOME/oraclient/$INSTANT_CLIENT${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$HOME/oraclient/$INSTANT_CLIENT/sqlplus" -s "admin/$DEFAULT_PASSWORD@$SERVICE_NAME" <<SQLEOF 2>/dev/null | tr -d '[:space:]'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF
$query
EXIT;
SQLEOF
}

# ── Optional: destructive rebuild ────────────────────────────────────────────
if $FROM_SCRATCH; then
  if ! $ASSUME_YES; then
    if [ -t 0 ]; then
      read -r -p "--from-scratch will stop/remove the '$CONTAINER_NAME' container and may prompt to delete its data dir. Continue? (y/N) " _confirm
      [ "$_confirm" = "y" ] || [ "$_confirm" = "Y" ] || { echo "Aborted."; exit 1; }
    else
      echo "ERROR: --from-scratch needs a confirmation — pass --yes for non-interactive runs." >&2
      exit 1
    fi
  fi

  if $ALSO_WIPE_DOCKER; then
    if ! $ASSUME_YES; then
      if [ -t 0 ]; then
        read -r -p "--also-wipe-docker will run setup-for-adb-26ai.sh -c, wiping ALL local Docker state (not just this repo's). Really continue? (y/N) " _confirm2
        [ "$_confirm2" = "y" ] || [ "$_confirm2" = "Y" ] || { echo "Aborted."; exit 1; }
      else
        echo "ERROR: --also-wipe-docker needs interactive confirmation even with --yes for --from-scratch." >&2
        exit 1
      fi
    fi
    sudo "$RUN_DIR/setup-for-adb-26ai.sh" -c
  fi

  "$RUN_DIR/run-adb-26ai.sh" -c || true
  sudo "$RUN_DIR/setup-for-adb-26ai.sh"
  "$RUN_DIR/run-adb-26ai.sh"
fi

# ── Assertions: infra + APEX reachable ───────────────────────────────────────
_health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
check "container '$CONTAINER_NAME' is healthy" "$([ "$_health" = "healthy" ] && echo true || echo false)" "status=$_health"

_http_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://localhost:$APEX_PORT/ords/" 2>/dev/null || echo "000")
case "$_http_code" in
  200|301|302|303) check "APEX/ORDS reachable on :$APEX_PORT" true ;;
  *) check "APEX/ORDS reachable on :$APEX_PORT" false "http_code=$_http_code" ;;
esac

_proxy_state=$(docker inspect --format='{{.State.Status}}' "$PROXY_CONTAINER" 2>/dev/null || echo "missing")
check "'$PROXY_CONTAINER' container running" "$([ "$_proxy_state" = "running" ] && echo true || echo false)" "status=$_proxy_state"

if [ -x "$HOME/oraclient/$INSTANT_CLIENT/sqlplus" ]; then
  _sql_ping=$(sql_scalar "SELECT 'PONG' FROM dual;")
  check "sqlplus connects as admin (wallet)" "$([ "$_sql_ping" = "PONG" ] && echo true || echo false)" "got='$_sql_ping'"

  _onnx_dir=$(sql_scalar "SELECT COUNT(*) FROM dba_directories WHERE directory_name = 'ONNX_STAGING';")
  check "ONNX_STAGING directory present" "$([ "$_onnx_dir" = "1" ] && echo true || echo false)" "count=$_onnx_dir"

  _max_str=$(sql_scalar "SELECT value FROM v\$parameter WHERE name='max_string_size';")
  check "MAX_STRING_SIZE=EXTENDED" "$([ "$(echo "$_max_str" | tr '[:lower:]' '[:upper:]')" = "EXTENDED" ] && echo true || echo false)" "value=$_max_str"
else
  check "sqlplus connects as admin (wallet)" false "sqlplus not found at $HOME/oraclient/$INSTANT_CLIENT — run setup-for-adb-26ai.sh"
  check "ONNX_STAGING directory present" false "skipped — sqlplus unavailable"
  check "MAX_STRING_SIZE=EXTENDED" false "skipped — sqlplus unavailable"
fi

# ── Optional: app import check ───────────────────────────────────────────────
if [ -n "$APP_FILE" ]; then
  if [ ! -f "$APP_FILE" ]; then
    check "APEX app import ($APP_FILE)" false "file not found"
  else
    _owner=$(apex_detect_owner "$APP_FILE")
    _app_id=$(apex_detect_app_id "$APP_FILE")
    if "$RUN_DIR/load-apex-app.sh" -f "$APP_FILE" >/tmp/smoke-adb-load.log 2>&1; then
      _app_check=$(sql_scalar "SELECT COUNT(*) FROM apex_applications WHERE application_id = $_app_id;")
      check "app $_app_id registered in apex_applications" "$([ "$_app_check" = "1" ] && echo true || echo false)" "count=$_app_check"

      _invalid=$(sql_scalar "SELECT COUNT(*) FROM all_objects WHERE owner = UPPER('$_owner') AND status = 'INVALID';")
      check "no INVALID objects for schema $_owner" "$([ "$_invalid" = "0" ] && echo true || echo false)" "invalid_count=$_invalid"
    else
      check "load-apex-app.sh -f $APP_FILE" false "see /tmp/smoke-adb-load.log"
      check "app $_app_id registered in apex_applications" false "skipped — import failed"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
_fail=0
for _r in "${_RESULTS[@]}"; do
  [ "${_r%%|*}" = "not ok" ] && _fail=$((_fail + 1))
done

if $JSON_OUT; then
  echo "{"
  echo "  \"total\": $_n,"
  echo "  \"failed\": $_fail,"
  echo "  \"checks\": ["
  for i in "${!_RESULTS[@]}"; do
    IFS='|' read -r _status _desc _diag <<< "${_RESULTS[$i]}"
    _comma=","; [ "$i" -eq $((${#_RESULTS[@]} - 1)) ] && _comma=""
    printf '    {"ok": %s, "description": "%s", "diagnostic": "%s"}%s\n' \
      "$([ "$_status" = "ok" ] && echo true || echo false)" "$_desc" "$_diag" "$_comma"
  done
  echo "  ]"
  echo "}"
else
  echo "1..$_n"
  echo ""
  if [ "$_fail" -eq 0 ]; then
    echo "All $_n checks passed."
  else
    echo "$_fail of $_n checks FAILED."
  fi
fi

[ "$_fail" -eq 0 ] && exit 0 || exit 1
