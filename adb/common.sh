#!/usr/bin/env bash
# common.sh — shared utilities sourced by all adb scripts.
# Requires: CONFIG_FILE and PLATFORM already set by the calling script.

# Read a single KEY=VALUE entry from CONFIG_FILE by exact key name.
# Handles values containing '=' (e.g. URLs). Strips inline comments and whitespace.
ini_val() {
    local key="$1"
    grep -m1 "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*//' | tr -d ' \n\r'
}

# Available disk space in KB for a given path (cross-platform).
avail_kb_for_dir() {
    local dir="$1"
    if [ "${PLATFORM:-}" = "darwin" ]; then
        df -k "$dir" 2>/dev/null | awk 'NR==2 {print $4}'
    else
        df "$dir" --output=avail 2>/dev/null | tail -1
    fi
}

# ─────────────────────────────────────────────────────────────────
# Colour output helpers — degrade gracefully when not on a colour terminal
# ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && tput colors &>/dev/null && [[ "$(tput colors)" -ge 8 ]]; then
    GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'
    BLD='\033[1m'; RST='\033[0m'
else
    GRN=''; RED=''; YLW=''; BLD=''; RST=''
fi

ok()   { printf "${GRN}  ✓${RST}  %s\n" "$*"; }
fail() { printf "${RED}  ✗${RST}  %s\n" "$*" >&2; }
warn() { printf "${YLW}  !${RST}  %s\n" "$*"; }
hdr()  { printf "\n${BLD}=== %s ===${RST}\n" "$*"; }
die()  { fail "$*"; exit 1; }
