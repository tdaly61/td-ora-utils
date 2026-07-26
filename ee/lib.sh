#!/usr/bin/env bash
# lib.sh — shared helpers for the ee/ (Database Free / Enterprise Edition) POC
# scripts. Sourced by every ee/*.sh script.
#
# Phase 1 scope note: this is a proof-of-concept toolkit, not the generic
# adb/-equivalent library (that's Phase 2). It intentionally reuses
# adb/common.sh's ini_val/platform_val/detect_platform/colour helpers instead
# of duplicating them, but keeps its own .env schema — see ee/.env.sample.

EE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ADB_DIR="$( cd "$EE_DIR/../adb" && pwd )"

CONFIG_FILE="$EE_DIR/.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found — copy ee/.env.sample to ee/.env first." >&2
    exit 1
fi

# shellcheck source=../adb/common.sh
source "$ADB_DIR/common.sh"
detect_platform

# Read a value from adb/.env instead of ee/.env — used only for host tooling
# genuinely shared with the adb-free setup (Instant Client location,
# DEFAULT_PASSWORD to seed the compat ADMIN user). Never writes to adb/.env.
adb_val() {
    local key="$1" saved="$CONFIG_FILE" v
    CONFIG_FILE="$ADB_DIR/.env"
    [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$ADB_DIR/config.ini"
    v="$(ini_val "$key")"
    CONFIG_FILE="$saved"
    printf '%s' "$v"
}

# Resolve a host path from ee/.env relative to EE_DIR, and require that it
# stays under EE_DIR — used before any rm -rf so a misconfigured .env can
# never point cleanup at something outside this toolkit's own directory.
resolve_ee_path() {
    local key="$1" default="$2" raw resolved
    raw="$(ini_val "$key")"
    raw="${raw:-$default}"
    resolved="$(cd "$EE_DIR" && realpath -m "$raw")"
    case "$resolved" in
        "$EE_DIR"/*) printf '%s' "$resolved" ;;
        *) die "$key resolves outside ee/ ($resolved) — refusing to use it for cleanup." ;;
    esac
}

# Exports TNS_ADMIN (cleared)/LD_LIBRARY_PATH/DYLD_LIBRARY_PATH and sets
# EE_SQLPLUS to the resolved sqlplus binary, for callers that need a genuine
# `sqlplus conn @script arg1 arg2` command-line invocation (positional args,
# correct @@-relative path resolution inside the script) rather than a
# heredoc-embedded one — apexins.sql specifically requires this: its nested
# @@core/scripts/*.sql references only resolve correctly when apexins.sql
# itself was invoked as a real command-line "@script" argument.
sqlplus_setup_env() {
    local instant_client oracle_client_dir
    instant_client="$(adb_instant_client)"
    oracle_client_dir="$HOME/oraclient"
    export TNS_ADMIN=""
    export LD_LIBRARY_PATH="$oracle_client_dir/$instant_client${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export DYLD_LIBRARY_PATH="$oracle_client_dir/$instant_client${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    EE_SQLPLUS="$(SQLPLUS_BIN)"
    export EE_SQLPLUS
}

SQLPLUS_BIN() {
    local instant_client oracle_client_dir sqlplus
    instant_client="$(adb_instant_client)"
    oracle_client_dir="$HOME/oraclient"
    sqlplus="$oracle_client_dir/$instant_client/sqlplus"
    if [ -x "$sqlplus" ]; then
        printf '%s' "$sqlplus"
    elif command -v sqlplus &>/dev/null; then
        printf '%s' "sqlplus"
    else
        die "sqlplus not found at $sqlplus and not on PATH. Run adb/setup-for-adb-26ai.sh first (shared Instant Client install)."
    fi
}

# Instant Client dir name, read from adb/.env via the same _MAC-aware logic
# common.sh already provides — just pointed at adb/.env instead of ee/.env.
adb_instant_client() {
    local saved="$CONFIG_FILE"
    CONFIG_FILE="$ADB_DIR/.env"
    [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$ADB_DIR/config.ini"
    local v
    v="$(platform_val INSTANT_CLIENT)"
    CONFIG_FILE="$saved"
    printf '%s' "$v"
}

# Run a SQL file via plain EZConnect (no wallet). Explicitly clears TNS_ADMIN
# so a stray adb-free wallet sqlnet.ora (which enforces TCPS) never leaks into
# a plain connection here.
# Usage: run_sql_ezconnect <user> <password> <ezconnect> <sql_file> [role]
#   role: optional, e.g. "sysdba" — appended as " as sysdba" after the
#   connect string (sqlplus requires the role outside the user/pass@dsn part,
#   not embedded in the password).
run_sql_ezconnect() {
    local user="$1" pass="$2" ezconnect="$3" sql_file="$4" role="${5:-}"
    local instant_client oracle_client_dir sqlplus connect_str
    instant_client="$(adb_instant_client)"
    oracle_client_dir="$HOME/oraclient"
    sqlplus="$(SQLPLUS_BIN)"
    [ -f "$sql_file" ] || die "SQL file not found: $sql_file"
    connect_str="$user/$pass@$ezconnect"
    [ -n "$role" ] && connect_str="$connect_str as $role"
    TNS_ADMIN="" \
    LD_LIBRARY_PATH="$oracle_client_dir/$instant_client${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    DYLD_LIBRARY_PATH="$oracle_client_dir/$instant_client${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
        "$sqlplus" -s "$connect_str" "@$sql_file"
}
