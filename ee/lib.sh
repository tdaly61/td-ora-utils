#!/usr/bin/env bash
# lib.sh — shared helpers for the ee/ (Oracle Database Enterprise Edition)
# POC scripts. Sourced by every ee/*.sh script.
#
# Scope note: this is a proof-of-concept toolkit, not the generic
# adb/-equivalent library (that library doesn't exist yet). It intentionally
# reuses adb/common.sh's ini_val/platform_val/detect_platform/colour helpers
# instead of duplicating them, but keeps its own .env schema — see
# ee/.env.sample.

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

# Ensure the host firewall lets Docker containers reach Ollama on 11434.
# Ported from adb/run-adb-26ai.sh's ensure_host_firewall_allows_ollama() —
# some HARDENED LINUX HOSTS (typically cloud VMs) run an iptables INPUT chain
# that only allows loopback/ICMP/established/SSH and REJECTs everything else,
# which silently breaks oracle-db -> host.docker.internal:11434 even though
# Ollama itself is up (curl to localhost works, container traffic gets "No
# route to host"). This does NOT apply on macOS/Colima or any host with a
# permissive default firewall policy — the check below is a no-op there.
#
# Unlike adb's version, this one does NOT modify the host firewall silently:
# inserting an iptables rule is a host-level, persistent change, so it
# requires an explicit one-time opt-in via ALLOW_FIREWALL_AUTOFIX=true in
# ee/.env (see .env.sample). Without it, this prints the exact command
# needed and how to enable auto-fix, but changes nothing — safe to run
# unattended (e.g. from full-cycle-test.sh) without surprising a host that's
# never seen this before.
ensure_host_firewall_allows_ollama() {
    echo "=== Checking host firewall allows Docker -> Ollama (11434) ==="

    if ! command -v iptables &>/dev/null; then
        echo "  iptables not found — skipping (no host firewall to configure; expected on macOS/Colima)."
        return 0
    fi

    # Reading iptables rules (-L) typically needs root too, not just -I/-C —
    # a plain unprivileged `iptables -L` commonly fails with "Permission
    # denied" and prints nothing, which would silently look identical to "no
    # catch-all rule exists". Resolve sudo-capability up front and use it for
    # every iptables invocation below, including this first detection check.
    local can_root=false
    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        can_root=true
    fi
    _iptables() { if [ "$(id -u)" -eq 0 ]; then iptables "$@"; else sudo -n iptables "$@"; fi; }

    if [ "$can_root" != "true" ]; then
        echo "  Not root and no passwordless sudo — cannot read iptables rules to check."
        echo "  If Ollama calls from the DB container fail with ORA-29273, this host may"
        echo "  need: sudo iptables -I INPUT 1 -p tcp -s <ee_default subnet> --dport 11434 -j ACCEPT"
        return 0
    fi

    if ! _iptables -L INPUT -n 2>/dev/null | grep -qE '^(REJECT|DROP)\b.*0\.0\.0\.0/0 +0\.0\.0\.0/0'; then
        echo "  No catch-all REJECT/DROP in INPUT chain — nothing to open."
        return 0
    fi

    local subnets
    subnets=$(docker network inspect ee_default \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | sort -u)
    [ -z "$subnets" ] && { echo "  ee_default network not found — skipping (run-ee.sh not up yet?)."; return 0; }

    local needed=() _subnet
    while IFS= read -r _subnet; do
        [ -z "$_subnet" ] && continue
        if _iptables -C INPUT -p tcp -s "$_subnet" --dport 11434 -j ACCEPT 2>/dev/null; then
            echo "  Rule already present for $_subnet:11434 — skipping."
        else
            needed+=("$_subnet")
        fi
    done <<< "$subnets"

    [ "${#needed[@]}" -eq 0 ] && return 0

    local autofix; autofix="$(ini_val ALLOW_FIREWALL_AUTOFIX)"
    if [ "$autofix" != "true" ]; then
        warn "Host firewall has a catch-all REJECT/DROP and NO exception yet for ee's"
        warn "docker network (${needed[*]}) on port 11434 — DBMS_VECTOR_CHAIN/UTL_HTTP"
        warn "calls to Ollama from inside the DB container will fail with ORA-29273"
        warn "(HTTP request failed) until this is opened, even though Ollama itself"
        warn "is running fine (this is a HOST firewall rule, not an Ollama problem)."
        warn "This is specific to hardened Linux hosts — not expected on macOS/Colima."
        echo ""
        echo "  To fix by hand, run once per subnet listed above:"
        for _subnet in "${needed[@]}"; do
            echo "    sudo iptables -I INPUT 1 -p tcp -s $_subnet --dport 11434 -j ACCEPT"
        done
        echo "  (insert before your existing catch-all REJECT/DROP line — check with"
        echo "   'sudo iptables -L INPUT -n --line-numbers' if line 1 isn't right)."
        echo ""
        echo "  Or set ALLOW_FIREWALL_AUTOFIX=true in ee/.env to have this script do"
        echo "  it for you (needs root or passwordless sudo) on the next run."
        return 0
    fi

    for _subnet in "${needed[@]}"; do
        echo "  ALLOW_FIREWALL_AUTOFIX=true — inserting ACCEPT rule for $_subnet -> tcp/11434..."
        local reject_line
        reject_line=$(_iptables -L INPUT -n --line-numbers 2>/dev/null \
            | awk '/^[0-9]+ +(REJECT|DROP)\b.*0\.0\.0\.0\/0 +0\.0\.0\.0\/0/ {print $1; exit}')
        _iptables -I INPUT "${reject_line:-1}" -p tcp -s "$_subnet" --dport 11434 -j ACCEPT
    done

    if command -v netfilter-persistent &>/dev/null; then
        if [ "$(id -u)" -eq 0 ]; then netfilter-persistent save; else sudo -n netfilter-persistent save; fi
        echo "  Firewall rules persisted via netfilter-persistent."
    else
        echo "  NOTE: netfilter-persistent not found — rules added but not persisted across reboot."
    fi
}

# Enable MAX_STRING_SIZE=EXTENDED so VARCHAR2(32767) columns are supported.
# Ported from adb/run-adb-26ai.sh's enable_extended_string_size() —
# ADB-Free has this pre-configured; plain Oracle Database (Enterprise
# Edition here) does NOT, and defaults to STANDARD (4000-byte VARCHAR2
# limit). Without this,
# any app whose schema declares a VARCHAR2 column over 4000 bytes fails
# CREATE TABLE with ORA-00910 ("specified length too long for its
# datatype") — discovered when caseweave's Supporting Objects install
# silently produced a database missing several core tables, which then
# surfaced much later as ORA-00942 ("table or view does not exist") in the
# Python worker daemons, far from the actual cause. Run this BEFORE
# installing any app.
#
# Idempotent (checks current value first) but genuinely invasive: it cycles
# the database through SHUTDOWN IMMEDIATE / STARTUP UPGRADE / normal
# STARTUP. Takes a couple of minutes. Uses `docker exec ... / as sysdba`
# (OS-authenticated bequeath) since it needs to survive the DB process
# restarting mid-session, which an external EZConnect session can't do.
# Usage: enable_extended_string_size <container_name> <oracle_pdb> [health_timeout]
enable_extended_string_size() {
    local container_name="$1" oracle_pdb="$2" health_timeout="${3:-300}"

    echo "=== Checking MAX_STRING_SIZE ==="

    local current
    current=$(docker exec -i "$container_name" sqlplus -s / as sysdba 2>/dev/null <<'SQLEOF' | tr -d '[:space:]'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TRIMOUT ON TRIMSPOOL ON
SELECT value FROM v$parameter WHERE name='max_string_size';
EXIT;
SQLEOF
    )

    if [ "$(echo "$current" | tr '[:lower:]' '[:upper:]')" = "EXTENDED" ]; then
        echo "  MAX_STRING_SIZE already EXTENDED — skipping."
        return 0
    fi

    echo "  MAX_STRING_SIZE=$current — enabling EXTENDED (DB will restart in UPGRADE mode, a couple of minutes)..."

    docker exec -i "$container_name" sqlplus -s / as sysdba <<'SQLEOF'
ALTER SYSTEM SET MAX_STRING_SIZE=EXTENDED SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP UPGRADE;
EXIT;
SQLEOF

    docker exec -i "$container_name" sqlplus -s / as sysdba <<SQLEOF
@?/rdbms/admin/utl32k.sql
ALTER PLUGGABLE DATABASE ALL OPEN UPGRADE;
ALTER SESSION SET CONTAINER=$oracle_pdb;
@?/rdbms/admin/utl32k.sql
ALTER SESSION SET CONTAINER=CDB\$ROOT;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQLEOF

    echo "  MAX_STRING_SIZE=EXTENDED enabled — waiting for DB to stabilise..."
    local start
    start=$(date +%s)
    while true; do
        local elapsed status
        elapsed=$(( $(date +%s) - start ))
        [ "$elapsed" -ge "$health_timeout" ] && die "Timeout waiting for $container_name to become healthy after MAX_STRING_SIZE upgrade."
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "starting")
        [ "$status" = "healthy" ] && { echo "  $container_name is healthy again (${elapsed}s)."; break; }
        sleep 10
    done
    echo "  MAX_STRING_SIZE=EXTENDED configured successfully."
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
