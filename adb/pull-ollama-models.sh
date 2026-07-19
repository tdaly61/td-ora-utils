#!/usr/bin/env bash
# pull-ollama-models.sh
# Pull the exact Ollama models an APEX app's AI pipeline needs, read from
# .env so there is a single source of truth (no hardcoded tags to drift).
#
# Resolved model set (platform-aware via common.sh platform_val, _MAC on Darwin):
#   - OLLAMA_VISION_MODEL   (image narration / vision pipeline, if your app uses one)
#   - OLLAMA_TEXT_MODEL     (summarisation / text pipeline)
#   - every local-type LLM_<ID> entry's <model> field (APEX Generative AI servers)
#
# Cross-platform: called by nvidia/ai-tools-setup.sh on Linux and usable directly
# on macOS (where Ollama is the desktop app). Idempotent — `ollama pull` re-pulls
# only changed layers.
#
# Usage: ./pull-ollama-models.sh [--check]
#   --check   print the resolved model list and exit without pulling

set -euo pipefail

RUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="$RUN_DIR/.env"; [ -f "$CONFIG_FILE" ] || CONFIG_FILE="$RUN_DIR/config.ini"
[ -f "$CONFIG_FILE" ] || { echo "ERROR: config not found ($RUN_DIR/.env or config.ini)" >&2; exit 1; }

# shellcheck source=common.sh
source "$RUN_DIR/common.sh"
detect_platform

# Bind Ollama on all interfaces so the DB container can reach it via
# host.docker.internal:11434. On Linux the systemd unit / launch step sets this;
# exporting here also covers ad-hoc `ollama serve` and the macOS app when this
# script is the entry point.
export OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0}"

# ── Resolve the required model set from config.ini ────────────────────────────
declare -A _WANT=()

_vision="$(platform_val OLLAMA_VISION_MODEL)"; [ -n "$_vision" ] && _WANT["$_vision"]=1
_text="$(platform_val OLLAMA_TEXT_MODEL)";     [ -n "$_text" ]   && _WANT["$_text"]=1

# local-type LLM_<ID> entries — pull their model field (prefer _MAC on Darwin).
declare -A _RAW=()
while IFS= read -r _line; do
  if [[ "$_line" =~ ^LLM_([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*([^|]+\|[^|]+\|[^|[:space:]]+) ]]; then
    _RAW["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  fi
done < "$CONFIG_FILE"
for _id in "${!_RAW[@]}"; do
  [[ "$_id" == *_MAC ]] && continue
  _spec="${_RAW[$_id]}"
  if [ "$PLATFORM" = "darwin" ] && [ -n "${_RAW[${_id}_MAC]:-}" ]; then
    _spec="${_RAW[${_id}_MAC]}"
  fi
  _type="${_spec##*|}"
  [ "$_type" = "local" ] || continue        # remote providers aren't Ollama-pulled
  _model="$(printf '%s' "$_spec" | cut -d'|' -f2)"
  [ -n "$_model" ] && _WANT["$_model"]=1
done

if [ "${#_WANT[@]}" -eq 0 ]; then
  echo "No local Ollama models resolved from config.ini — nothing to pull."
  exit 0
fi

echo "Required Ollama models (from config.ini, platform=$PLATFORM):"
for m in "${!_WANT[@]}"; do echo "  - $m"; done

if [ "${1:-}" = "--check" ]; then
  exit 0
fi

command -v ollama >/dev/null 2>&1 || { echo "ERROR: ollama not found on PATH." >&2; exit 1; }

_failed=()
for m in "${!_WANT[@]}"; do
  echo ""
  echo "=== ollama pull $m ==="
  if ollama pull "$m"; then
    echo "  ok: $m"
  else
    echo "  FAILED: $m" >&2
    _failed+=("$m")
  fi
done

echo ""
if [ "${#_failed[@]}" -gt 0 ]; then
  echo "WARNING: failed to pull: ${_failed[*]}" >&2
  echo "  Check the tag exists (https://ollama.com/library) or adjust config.ini." >&2
  exit 1
fi
echo "All required models present."
