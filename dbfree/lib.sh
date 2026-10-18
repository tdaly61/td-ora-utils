#!/usr/bin/env bash
# lib.sh — shared helpers for the dbfree/ (Oracle Database Free) POC
# scripts. Sourced by every dbfree/*.sh script.
#
# Sources common.sh (generic ini_val/platform_val/detect_platform/
# select_docker_image/colour helpers).

DBFREE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

CONFIG_FILE="$DBFREE_DIR/.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found — copy dbfree/.env.sample to dbfree/.env first." >&2
    exit 1
fi

# shellcheck source=./common.sh
source "$DBFREE_DIR/common.sh"
detect_platform

# Resolve a host path from dbfree/.env relative to DBFREE_DIR, and require that it
# stays under DBFREE_DIR — used before any rm -rf so a misconfigured .env can
# never point cleanup at something outside this toolkit's own directory.
resolve_dbfree_path() {
    local key="$1" default="$2" raw resolved realpath_bin
    raw="$(ini_val "$key")"
    raw="${raw:-$default}"
    # macOS's built-in BSD realpath has no -m (resolve without requiring the
    # path to exist yet, needed here since setup-for-dbfree.sh calls this before
    # creating the directories) — use GNU realpath (grealpath, via `brew
    # install coreutils`) on macOS instead.
    if [ "$PLATFORM" = "darwin" ]; then
        command -v grealpath &>/dev/null || die "grealpath not found — run: brew install coreutils"
        realpath_bin="grealpath"
    else
        realpath_bin="realpath"
    fi
    resolved="$(cd "$DBFREE_DIR" && "$realpath_bin" -m "$raw")"
    case "$resolved" in
        "$DBFREE_DIR"/*) printf '%s' "$resolved" ;;
        *) die "$key resolves outside dbfree/ ($resolved) — refusing to use it for cleanup." ;;
    esac
}

# Source for the DB container's /opt/oracle/oradata mount. On macOS it's a
# Docker named volume (inside the Colima VM): a host bind mount goes through
# virtiofs, where DBCA creates FREEPDB1 but can't open it (ORA-65009, then
# ORA-27041 on control01.ctl) and the container exits on first boot. Linux
# keeps the plain DB_DATA_DIR bind mount. Prints the compose volume key
# "oradata" on macOS (see docker-compose.yml's top-level volumes:).
db_data_source() {
    if [ "$PLATFORM" = "darwin" ]; then
        printf 'oradata'
    else
        resolve_dbfree_path DB_DATA_DIR ./oradata
    fi
}

# Docker volume name behind db_data_source() on macOS.
db_data_volume() {
    local v; v="$(ini_val DB_DATA_VOLUME)"
    printf '%s' "${v:-dbfree-oradata}"
}

# Colima profile behind the current docker context ("colima" -> default,
# "colima-foo" -> foo). Prints nothing if the context isn't a Colima one
# (Docker Desktop, plain Linux dockerd, ...).
colima_profile() {
    local ctx
    ctx="$(docker context show 2>/dev/null || true)"
    case "$ctx" in
        colima)   printf 'default' ;;
        colima-*) printf '%s' "${ctx#colima-}" ;;
    esac
}

# Check the Docker engine has enough memory/CPUs for oracle-db + ords +
# apexins.sql. On macOS that's the Colima VM's allocation, NOT the Mac's RAM —
# Colima's out-of-the-box default (2GB/2 CPUs) is too small: the DB either
# gets OOM-killed or swaps so hard that the health wait / apexins.sql looks
# like a silent hang. `docker info` reports what the engine actually sees, so
# this works for any runtime.
#
# Below DOCKER_MIN_MEMORY_GB: prints fix instructions and returns 1 (callers
# die / preflight_fail). Below DOCKER_RECOMMENDED_MEMORY_GB: warns only.
# With COLIMA_AUTO_RESIZE=true in dbfree/.env, a too-small Colima VM is
# restarted at the recommended size instead — opt-in because restarting
# Colima stops EVERY container running in it, not just this stack's.
check_docker_resources() {
    local min_gb rec_gb mem_bytes="" ncpu="" mem_mb profile host_gb target_gb cpus
    min_gb="$(ini_val DOCKER_MIN_MEMORY_GB)"; min_gb="${min_gb:-4}"
    rec_gb="$(ini_val DOCKER_RECOMMENDED_MEMORY_GB)"; rec_gb="${rec_gb:-8}"

    read -r mem_bytes ncpu < <(docker info --format '{{.MemTotal}} {{.NCPU}}' 2>/dev/null) || true
    if [ -z "$mem_bytes" ]; then
        fail "Docker daemon is not reachable — start Colima (\`colima start --memory $rec_gb --cpus 4\`) or your Docker runtime, then re-run."
        return 1
    fi
    mem_mb=$((mem_bytes / 1024 / 1024))
    profile="$(colima_profile)"

    # The engine reports a little less than the VM's configured size (an 8GB
    # Colima VM shows ~7.7GiB), so compare against 90% of each threshold.
    if [ "$mem_mb" -ge $((rec_gb * 1024 * 9 / 10)) ]; then
        ok "Docker has ${mem_mb}MB memory / ${ncpu} CPUs${profile:+ (Colima profile '$profile')}"
        return 0
    fi

    host_gb=""
    if [ "$PLATFORM" = "darwin" ]; then
        host_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    fi
    # Leave the Mac itself (and Ollama, which runs on the host) at least 4GB.
    target_gb="$rec_gb"
    if [ -n "$host_gb" ] && [ "$host_gb" -gt 0 ] && [ $((host_gb - 4)) -lt "$target_gb" ]; then
        target_gb=$(( host_gb - 4 > min_gb ? host_gb - 4 : min_gb ))
    fi
    cpus=$(( ncpu > 4 ? ncpu : 4 ))
    local pflag=""
    [ -n "$profile" ] && [ "$profile" != "default" ] && pflag=" -p $profile"

    if [ -n "$profile" ] && [ "$(ini_val COLIMA_AUTO_RESIZE)" = "true" ]; then
        warn "Colima VM has only ${mem_mb}MB — COLIMA_AUTO_RESIZE=true, restarting it with ${target_gb}GB / ${cpus} CPUs (this stops every container in it)..."
        # shellcheck disable=SC2086
        colima stop$pflag && colima start$pflag --memory "$target_gb" --cpus "$cpus" \
            || { fail "Colima resize failed — run it by hand: colima stop$pflag && colima start$pflag --memory $target_gb --cpus $cpus"; return 1; }
        read -r mem_bytes ncpu < <(docker info --format '{{.MemTotal}} {{.NCPU}}' 2>/dev/null) || true
        mem_mb=$(( ${mem_bytes:-0} / 1024 / 1024 ))
        ok "Colima restarted: Docker now has ${mem_mb}MB memory / ${ncpu} CPUs"
        [ "$mem_mb" -ge $((min_gb * 1024 * 9 / 10)) ] && return 0
    fi

    local fix
    if [ -n "$profile" ]; then
        fix="Colima's VM is too small (Colima defaults to 2GB). Resize it — this restarts the VM and every container in it:
        colima stop$pflag
        colima start$pflag --memory $target_gb --cpus $cpus
     Check the result with: colima list   (or set COLIMA_AUTO_RESIZE=true in dbfree/.env to have this script do it)."
    elif [ "$PLATFORM" = "darwin" ]; then
        fix="Raise the memory limit for your Docker runtime's VM to ${target_gb}GB+ (e.g. Docker Desktop -> Settings -> Resources)."
    else
        fix="This host has too little RAM for the stack — free memory or use a larger machine."
    fi
    [ -n "$host_gb" ] && [ "$host_gb" -gt 0 ] && [ "$host_gb" -lt $((min_gb + 4)) ] \
        && fix="$fix
     Note: this Mac has only ${host_gb}GB RAM in total — with Ollama also running on the host it will be tight."

    if [ "$mem_mb" -lt $((min_gb * 1024 * 9 / 10)) ]; then
        fail "Docker has only ${mem_mb}MB memory — the dbfree stack needs at least ${min_gb}GB (${rec_gb}GB recommended). Without it the DB gets OOM-killed or swaps, and run-dbfree.sh appears to hang."
        printf '     %s\n' "$fix" >&2
        return 1
    fi
    warn "Docker has only ${mem_mb}MB memory / ${ncpu} CPUs — works, but ${rec_gb}GB is recommended (APEX install will be slow)."
    printf '     %s\n' "$fix"
    return 0
}

# ── LLM: Ollama on the host ───────────────────────────────────────────────
# OLLAMA_BASE_URL is how the DB container reaches Ollama; the host reaches the
# same server on localhost.
ollama_container_url() {
    local url; url="$(platform_val OLLAMA_BASE_URL)"
    printf '%s' "${url:-http://host.docker.internal:11434}"
}
ollama_host_url() {
    local url; url="$(ollama_container_url)"
    printf '%s' "${url/host.docker.internal/localhost}"
}

# Every Ollama model dbfree/.env names, one per line: OLLAMA_MODEL, the model
# in each type=local LLM_<ID> entry, and WORKER_TEXT/VISION_MODEL when
# WORKER_LLM_API_STYLE is ollama. _MAC variants win on macOS.
llm_models() {
    local key spec style
    {
        platform_val OLLAMA_MODEL; echo
        for key in $(grep -oE '^LLM_[A-Za-z0-9_]+=' "$CONFIG_FILE" | tr -d '=' | grep -v '_MAC$'); do
            spec="$(platform_val "$key")"
            if [ "${spec##*|}" = "local" ]; then printf '%s\n' "$spec" | cut -d'|' -f2; fi
        done
        style="$(platform_val WORKER_LLM_API_STYLE)"
        if [ "${style:-ollama}" = "ollama" ]; then
            platform_val WORKER_TEXT_MODEL; echo
            platform_val WORKER_VISION_MODEL; echo
        fi
    } | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$' | awk '!seen[$0]++'
}

# Check Ollama is installed, running, reachable from Docker containers, and
# has every model llm_models lists, printing the fix for each problem. Missing
# models go in LLM_MISSING (pull_llm_models fetches them) and don't count as
# problems; a model too big for this Mac's spare memory is a warning only.
# Returns the number of problems.
check_llm() {
    local url inner tags model size biggest=0 biggest_name="" problems=0
    url="$(ollama_host_url)"; inner="$(ollama_container_url)"
    LLM_MISSING=()

    if ! command -v ollama &>/dev/null && [[ "$url" == http://localhost* ]]; then
        fail "Ollama is not installed — the database's AI calls and any app's LLM workers need it."
        if [ "$PLATFORM" = "darwin" ]; then
            echo "     Install: brew install ollama   (or the app from https://ollama.com/download)"
        else
            echo "     Install: curl -fsSL https://ollama.com/install.sh | sh"
        fi
        return 1
    fi

    if ! tags="$(curl -sf -m 5 "$url/api/tags")"; then
        fail "Ollama is not answering at $url."
        if [ "$PLATFORM" = "darwin" ]; then
            echo "     Start it: open -a Ollama   (or in a terminal: ollama serve)"
        else
            echo "     Start it: sudo systemctl start ollama   (or in a terminal: ollama serve)"
        fi
        echo "     Using another server? Set OLLAMA_BASE_URL in dbfree/.env."
        return 1
    fi
    ok "Ollama is running at $url"

    # The DB container calls Ollama from inside Docker, which fails if Ollama
    # only listens on the host's loopback (the Linux default) or a firewall
    # blocks it, even though everything above passed.
    if docker info &>/dev/null; then
        if docker run --rm --add-host host.docker.internal:host-gateway alpine \
                wget -q -T 5 -O /dev/null "$inner/api/version" &>/dev/null; then
            ok "Docker containers can reach Ollama at $inner"
        else
            fail "Docker containers can't reach Ollama at $inner (the host can, so Ollama is probably listening on localhost only)."
            if [ "$PLATFORM" = "darwin" ]; then
                echo "     Quit the Ollama app, then run in a terminal: OLLAMA_HOST=0.0.0.0 ollama serve"
            else
                echo "     Make it listen on all interfaces, then restart it:"
                echo "       sudo systemctl edit ollama      # add the two lines: [Service]  Environment=\"OLLAMA_HOST=0.0.0.0\""
                echo "       sudo systemctl restart ollama"
                echo "     If it still fails, see the firewall note for ALLOW_FIREWALL_AUTOFIX in dbfree/.env."
            fi
            problems=$((problems + 1))
        fi
    fi

    # /api/tags lists each model's "name" followed (a few keys later) by its
    # "size" in bytes; a name without a tag means ":latest".
    while IFS= read -r model; do
        [[ "$model" == *:* ]] || model="$model:latest"
        size="$(printf '%s' "$tags" | grep -oE '"name":"[^"]+"|"size":[0-9]+' \
            | grep -A1 -Fx "\"name\":\"$model\"" | sed -n 's/^"size"://p')"
        if [ -n "$size" ]; then
            ok "Model $model is pulled ($(( (size + 2**29) / 2**30 ))GB)"
            if [ "$size" -gt "$biggest" ]; then biggest=$size; biggest_name=$model; fi
        else
            LLM_MISSING+=("$model")
        fi
    done < <(llm_models)

    if [ "${#LLM_MISSING[@]}" -gt 0 ]; then
        warn "Not pulled yet: ${LLM_MISSING[*]}"
        echo "     ./setup-for-dbfree.sh -l pulls them (or by hand: ollama pull <model>)."
        echo "     The models come from OLLAMA_MODEL, LLM_<ID> and WORKER_*_MODEL in dbfree/.env."
    fi

    # On a Mac, Ollama shares RAM with the Colima VM: a model bigger than what's
    # left over loads very slowly, swaps, or fails with an out-of-memory error.
    if [ "$PLATFORM" = "darwin" ] && [ "$biggest" -gt 0 ]; then
        local host docker_mem spare
        host="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
        docker_mem="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
        spare=$(( host - docker_mem - 4 * 2**30 ))
        if [ "$biggest" -gt "$spare" ]; then
            warn "$biggest_name needs at least $(( (biggest + 2**29) / 2**30 ))GB, but this Mac has $(( host / 2**30 ))GB with $(( docker_mem / 2**30 ))GB given to Docker — expect very slow answers or out-of-memory errors."
            echo "     Pick a smaller model in dbfree/.env (e.g. WORKER_TEXT_MODEL_MAC=llama3.2:3b), or give Docker less memory."
        fi
    fi
    return "$problems"
}

# Pull the models check_llm found missing (LLM_MISSING).
pull_llm_models() {
    local model
    [ "${#LLM_MISSING[@]}" -gt 0 ] || return 0
    command -v ollama &>/dev/null || die "The ollama command isn't installed here — pull these on the Ollama server instead: ${LLM_MISSING[*]}"
    for model in "${LLM_MISSING[@]}"; do
        echo "  ollama pull $model   (large models take a while)"
        OLLAMA_HOST="$(ollama_host_url)" ollama pull "$model" \
            || die "Couldn't pull $model. Check the name at https://ollama.com/library — or, if it's a custom model made with 'ollama create', create it on this machine first — or pick another model in dbfree/.env."
        ok "Pulled $model"
    done
    LLM_MISSING=()
}

# Wait for a container to report healthy, failing fast (instead of spinning
# until the timeout) if it exits or is OOM-killed, and printing progress every
# minute so a slow first boot doesn't look like a hang.
# Usage: wait_for_container_healthy <container_name> <timeout_seconds>
wait_for_container_healthy() {
    local name="$1" timeout="$2" start elapsed state health oom last_report=0
    echo "Waiting up to ${timeout}s for $name to be healthy (first boot creates the DB — typically 3-10 minutes)..."
    start=$(date +%s)
    while true; do
        elapsed=$(( $(date +%s) - start ))
        read -r state health oom < <(docker inspect --format \
            '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.OOMKilled}}' \
            "$name" 2>/dev/null) || true

        if [ "${oom:-false}" = "true" ]; then
            die "$name was OOM-killed — Docker doesn't have enough memory for Oracle. Re-run after resizing (see the memory check at the start of this script's output), e.g. on Colima: colima stop && colima start --memory 8 --cpus 4"
        fi
        case "${state:-missing}" in
            exited|dead|missing)
                docker logs --tail 30 "$name" 2>&1 | sed 's/^/     | /' >&2 || true
                die "$name is no longer running (state: ${state:-missing}) — last log lines above. If they show memory errors (ORA-04031/ORA-27125/'Killed'), give Docker more memory." ;;
        esac
        [ "$health" = "healthy" ] && { ok "$name is healthy (${elapsed}s)"; return 0; }
        [ "$health" = "unhealthy" ] && die "$name reported unhealthy — check: docker logs $name. Common causes: too little memory allocated to Colima/Docker (the DB wants a few GB headroom beyond its own SGA/PGA), the host is out of disk space, or (on macOS/Colima) a stuck NAT state on DB_HOST_PORT — see README.md's stuck-port gotcha."
        [ "$elapsed" -ge "$timeout" ] && die "Timeout after ${timeout}s waiting for $name to become healthy (state: $state, health: $health). Check: docker logs $name — a DB that never finishes booting is most often starved of memory/CPU (see the memory check at the start of this script's output)."

        if [ $((elapsed - last_report)) -ge 60 ]; then
            last_report=$elapsed
            echo "  ...${elapsed}s, $name is $state/$health. Last log: $(docker logs --tail 1 "$name" 2>&1 | cut -c1-120)"
        fi
        sleep 10
    done
}

# Exports TNS_ADMIN (cleared)/LD_LIBRARY_PATH/DYLD_LIBRARY_PATH and sets
# DBFREE_SQLPLUS to the resolved sqlplus binary, for callers that need a genuine
# `sqlplus conn @script arg1 arg2` command-line invocation (positional args,
# correct @@-relative path resolution inside the script) rather than a
# heredoc-embedded one — apexins.sql specifically requires this: its nested
# @@core/scripts/*.sql references only resolve correctly when apexins.sql
# itself was invoked as a real command-line "@script" argument.
sqlplus_setup_env() {
    local instant_client oracle_client_dir
    instant_client="$(resolve_instant_client)"
    oracle_client_dir="$HOME/oraclient"
    export TNS_ADMIN=""
    export LD_LIBRARY_PATH="$oracle_client_dir/$instant_client${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export DYLD_LIBRARY_PATH="$oracle_client_dir/$instant_client${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    DBFREE_SQLPLUS="$(SQLPLUS_BIN)"
    export DBFREE_SQLPLUS
}

# Ensure the host firewall lets Docker containers reach Ollama on 11434.
# Some HARDENED LINUX HOSTS (typically cloud VMs) run an iptables INPUT chain
# that only allows loopback/ICMP/established/SSH and REJECTs everything else,
# which silently breaks oracle-db -> host.docker.internal:11434 even though
# Ollama itself is up (curl to localhost works, container traffic gets "No
# route to host"). This does NOT apply on macOS/Colima or any host with a
# permissive default firewall policy — the check below is a no-op there.
#
# This does NOT modify the host firewall silently: inserting an iptables
# rule is a host-level, persistent change, so it requires an explicit one-time opt-in via ALLOW_FIREWALL_AUTOFIX=true in
# dbfree/.env (see .env.sample). Without it, this prints the exact command
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
        echo "  need: sudo iptables -I INPUT 1 -p tcp -s <dbfree_default subnet> --dport 11434 -j ACCEPT"
        return 0
    fi

    if ! _iptables -L INPUT -n 2>/dev/null | grep -qE '^(REJECT|DROP)\b.*0\.0\.0\.0/0 +0\.0\.0\.0/0'; then
        echo "  No catch-all REJECT/DROP in INPUT chain — nothing to open."
        return 0
    fi

    local subnets
    subnets=$(docker network inspect dbfree_default \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null | sort -u)
    [ -z "$subnets" ] && { echo "  dbfree_default network not found — skipping (run-dbfree.sh not up yet?)."; return 0; }

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
        warn "Host firewall has a catch-all REJECT/DROP and NO exception yet for dbfree's"
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
        echo "  Or set ALLOW_FIREWALL_AUTOFIX=true in dbfree/.env to have this script do"
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
# Plain Oracle Database defaults to STANDARD (4000-byte VARCHAR2 limit).
# Without this,
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

    # utl32k.sql must run in CDB$ROOT AND every PDB that needs to open
    # normally afterwards — PDB$SEED included. Skipping PDB$SEED here left it
    # unable to complete its own migration, so plain STARTUP afterwards
    # couldn't reopen it (ORA-14696) and it stayed MOUNTED forever — which
    # the Database Free image's own healthcheck (checkDBStatus.sh) treats as
    # unhealthy for ANY PDB, permanently failing the container's health
    # status even though the actual app PDB was fine. Confirmed empirically.
    docker exec -i "$container_name" sqlplus -s / as sysdba <<SQLEOF
@?/rdbms/admin/utl32k.sql
ALTER PLUGGABLE DATABASE ALL OPEN UPGRADE;
ALTER SESSION SET CONTAINER=PDB\$SEED;
@?/rdbms/admin/utl32k.sql
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

# Raise PGA_AGGREGATE_LIMIT above Database Free's 2G default (vector-embedding
# workers hit ORA-04036 at the default). It's an ordinary DBA-adjustable init
# parameter — confirmed empirically (2G -> 4G, took effect immediately).
# SCOPE=BOTH so it applies now AND survives the container restart.
# Usage: set_pga_aggregate_limit <container_name> <limit e.g. 3G>
set_pga_aggregate_limit() {
    local container_name="$1" limit="$2"

    echo "=== Setting PGA_AGGREGATE_LIMIT=$limit ==="

    local current
    current=$(docker exec -i "$container_name" sqlplus -s / as sysdba 2>/dev/null <<'SQLEOF' | tr -d '[:space:]'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TRIMOUT ON TRIMSPOOL ON
SELECT value FROM v$parameter WHERE name='pga_aggregate_limit';
EXIT;
SQLEOF
    )

    if [ "$(echo "$current" | tr '[:lower:]' '[:upper:]')" = "$(echo "$limit" | tr '[:lower:]' '[:upper:]')" ]; then
        echo "  PGA_AGGREGATE_LIMIT already $limit — skipping."
        return 0
    fi

    local out
    out=$(docker exec -i "$container_name" sqlplus -s / as sysdba <<SQLEOF 2>&1
ALTER SYSTEM SET pga_aggregate_limit=$limit SCOPE=BOTH;
EXIT;
SQLEOF
    )
    echo "$out"
    echo "$out" | grep -qiE "ORA-|SP2-" && die "Failed to set PGA_AGGREGATE_LIMIT=$limit — see sqlplus output above (if this is ORA-01031, $container_name is not plain Database Free — check DOCKER_IMAGE_ARM/DOCKER_IMAGE_AMD in dbfree/.env)."
    echo "  PGA_AGGREGATE_LIMIT=$limit configured successfully."
}

SQLPLUS_BIN() {
    local instant_client oracle_client_dir sqlplus
    instant_client="$(resolve_instant_client)"
    oracle_client_dir="$HOME/oraclient"
    sqlplus="$oracle_client_dir/$instant_client/sqlplus"
    if [ -x "$sqlplus" ]; then
        printf '%s' "$sqlplus"
    elif command -v sqlplus &>/dev/null; then
        printf '%s' "sqlplus"
    else
        die "sqlplus not found at $sqlplus and not on PATH. Run ./setup-for-dbfree.sh first (it installs the Instant Client)."
    fi
}

# Run a SQL file via plain EZConnect (no wallet). Explicitly clears TNS_ADMIN
# so a stray wallet sqlnet.ora never leaks into a plain connection here.
# Usage: run_sql_ezconnect <user> <password> <ezconnect> <sql_file> [role]
#   role: optional, e.g. "sysdba" — appended as " as sysdba" after the
#   connect string (sqlplus requires the role outside the user/pass@dsn part,
#   not embedded in the password).
run_sql_ezconnect() {
    local user="$1" pass="$2" ezconnect="$3" sql_file="$4" role="${5:-}"
    local instant_client oracle_client_dir sqlplus connect_str
    instant_client="$(resolve_instant_client)"
    oracle_client_dir="$HOME/oraclient"
    sqlplus="$(SQLPLUS_BIN)"
    [ -f "$sql_file" ] || die "SQL file not found: $sql_file"
    connect_str="$user/$pass@$ezconnect"
    [ -n "$role" ] && connect_str="$connect_str as $role"
    # < /dev/null: if the script ever lacked a trailing EXIT, sqlplus would
    # otherwise drop into interactive mode and hang on whatever stdin this
    # call inherited — forces immediate EOF instead (same fix applied to
    # every other positional "@script" sqlplus call in this toolkit).
    TNS_ADMIN="" \
    LD_LIBRARY_PATH="$oracle_client_dir/$instant_client${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    DYLD_LIBRARY_PATH="$oracle_client_dir/$instant_client${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
        "$sqlplus" -s "$connect_str" "@$sql_file" < /dev/null
}
