#!/usr/bin/env bash
# common.sh — shared utilities sourced by all adb scripts.
# Requires: CONFIG_FILE set by the calling script before ini_val/platform_val are used.
# detect_platform (below) sets PLATFORM/ARCH — call it right after sourcing this file.

# Detect PLATFORM (linux|darwin) and ARCH (x86_64|arm64|aarch64) from uname.
# Every adb script should source common.sh then call this once, instead of
# carrying its own copy.
detect_platform() {
    case "$(uname -s)" in
        Linux*)  PLATFORM=linux ;;
        Darwin*) PLATFORM=darwin ;;
        *) echo "Unsupported platform: $(uname -s). Exiting."; exit 1 ;;
    esac
    ARCH=$(uname -m)   # x86_64 | arm64 | aarch64
}

# Read a single KEY=VALUE entry from CONFIG_FILE by exact key name.
# Handles values containing '=' (e.g. URLs). Strips inline comments and whitespace.
ini_val() {
    local key="$1"
    grep -m1 "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*//' | tr -d ' \n\r'
}

# Read a config value with a platform override. On macOS (PLATFORM=darwin) prefer
# the KEY_MAC entry, falling back to the plain KEY when KEY_MAC is empty/absent.
# On Linux (or any non-darwin) return the plain KEY. This centralises the
# _MAC-preferred/base-fallback pattern already used ad hoc for INSTANT_CLIENT etc.
platform_val() {
    local key="$1" v=""
    if [ "${PLATFORM:-}" = "darwin" ]; then
        v="$(ini_val "${key}_MAC")"
    fi
    [ -z "$v" ] && v="$(ini_val "$key")"
    printf '%s' "$v"
}

# Resolve the Docker image for the effective CPU architecture from
# DOCKER_IMAGE_ARM / DOCKER_IMAGE_AMD (falling back to plain DOCKER_IMAGE if
# an arch-specific key is absent). On macOS, COLIMA_ARCH overrides the host's
# uname -m — e.g. a Colima VM running x86_64 emulation on Apple Silicon needs
# the AMD64 image even though `uname -m` reports arm64.
# Requires: PLATFORM, ARCH already set (detect_platform) and CONFIG_FILE/ini_val.
# Prints the resolved image to stdout; callers log the choice themselves.
select_docker_image() {
    local eff_arch="$ARCH"
    if [ "${PLATFORM:-}" = "darwin" ]; then
        local colima_arch
        colima_arch="$(ini_val COLIMA_ARCH 2>/dev/null | tr -d ' \n\r' || true)"
        [ -n "$colima_arch" ] && eff_arch="$colima_arch"
    fi
    local img_arm img_amd img_fallback
    img_arm="$(ini_val DOCKER_IMAGE_ARM 2>/dev/null | tr -d ' \n\r' || true)"
    img_amd="$(ini_val DOCKER_IMAGE_AMD 2>/dev/null | tr -d ' \n\r' || true)"
    img_fallback="$(ini_val DOCKER_IMAGE 2>/dev/null | tr -d ' \n\r' || true)"
    case "$eff_arch" in
        x86_64|amd64)  printf '%s' "${img_amd:-$img_fallback}" ;;
        arm64|aarch64) printf '%s' "${img_arm:-$img_fallback}" ;;
        *)             printf '%s' "$img_fallback" ;;
    esac
}

# Resolve the Instant Client directory name for the current platform: prefer
# INSTANT_CLIENT_MAC on Darwin (falling back to the plain key), plain
# INSTANT_CLIENT elsewhere. Thin wrapper over platform_val kept as a named
# entry point so callers read clearly.
resolve_instant_client() {
    platform_val INSTANT_CLIENT
}

# Parse the parsing-schema owner out of an APEX export file
# (,p_default_owner=>'SCHEMANAME'). Prints empty if not found.
apex_detect_owner() {
    local file="$1"
    grep -m1 "p_default_owner" "$file" \
        | sed "s/.*p_default_owner=>['\"]\\([^'\"]*\\)['\"].*/\\1/" \
        | tr -d ' \r\n'
}

# Parse the application ID out of an APEX export file
# (,p_default_application_id=>316). Prints empty if not found.
apex_detect_app_id() {
    local file="$1"
    grep -m1 "p_default_application_id" "$file" \
        | sed "s/.*p_default_application_id=>['\">]*\([0-9]*\).*/\1/" \
        | tr -d ' \r\n'
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
