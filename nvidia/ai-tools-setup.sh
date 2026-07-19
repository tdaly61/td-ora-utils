#!/usr/bin/env bash
# ==============================================================================
# ai-tools-setup.sh
# Install Ollama, Claude Code, OpenCode and pull recommended local LLM models
# on Ubuntu 24.04 with NVIDIA GPU support.
#
# Tested hardware profile: NVIDIA A10 (23GB VRAM), 235GB+ RAM, 30-core Xeon
#
# Usage:
#   sudo ./ai-tools-setup.sh [OPTIONS]
#
# Options:
#   --skip-models   Install tools only, do not pull any models
#   --models-only   Skip tool install, only pull models (Ollama must be running)
#   --check         Show what would be installed / pulled and exit
#   --cleanup       Remove Ollama, models, Claude Code, OpenCode, uv
#   --help          Show this help message
#
# Models pulled by default:
#   Pipeline models (from adb/.env via adb/pull-ollama-models.sh — the
#   single source of truth for the APEX app's vision + text + local LLM_*
#   models, e.g. gemma4:26b, llama3.3:70b).
#   Plus these extra developer/coding models:
#     qwen2.5-coder:32b     - best coding model for A10 (fits in 23GB VRAM at Q4)
#     devstral              - Mistral coding model, GPU-friendly alternative
#     mistral-small3.1:24b  - fast GPU exploration / Q&A
#     deepseek-r1:32b       - reasoning + code review, fits in GPU
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colours / helpers
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

die() { error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
SKIP_MODELS=false
MODELS_ONLY=false
CHECK_ONLY=false
DO_CLEANUP=false

for arg in "$@"; do
  case "$arg" in
    --skip-models)  SKIP_MODELS=true ;;
    --models-only)  MODELS_ONLY=true ;;
    --check)        CHECK_ONLY=true  ;;
    --cleanup)      DO_CLEANUP=true  ;;
    --help|-h)
      sed -n '3,30p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown option: $arg" ;;
  esac
done

# ------------------------------------------------------------------------------
# Root check (not needed for --models-only or --check)
# ------------------------------------------------------------------------------
if [[ "$MODELS_ONLY" == "false" && "$CHECK_ONLY" == "false" ]]; then
  [[ $EUID -eq 0 ]] || die "Run with sudo for tool installation: sudo $0 $*"
fi

# ------------------------------------------------------------------------------
# Cleanup — remove everything this script installs
# ------------------------------------------------------------------------------
if [[ "$DO_CLEANUP" == "true" ]]; then
  [[ $EUID -eq 0 ]] || die "Run with sudo for cleanup: sudo $0 --cleanup"
  header "Cleaning up AI tools"

  # Remove Ollama models first (while service is still running)
  if command -v ollama &>/dev/null; then
    info "Removing all Ollama models..."
    for model in $(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}'); do
      info "  Removing model: $model"
      ollama rm "$model" 2>/dev/null || true
    done
  fi

  # Stop and remove Ollama
  if systemctl is-active --quiet ollama 2>/dev/null; then
    info "Stopping Ollama service..."
    systemctl stop ollama
    systemctl disable ollama 2>/dev/null || true
  fi
  if [[ -f /etc/systemd/system/ollama.service.d/override.conf ]]; then
    info "Removing Ollama systemd override..."
    rm -f /etc/systemd/system/ollama.service.d/override.conf
    rmdir /etc/systemd/system/ollama.service.d 2>/dev/null || true
    systemctl daemon-reload
  fi
  if command -v ollama &>/dev/null; then
    info "Removing Ollama binary and data..."
    rm -f /usr/local/bin/ollama
    rm -rf /usr/share/ollama 2>/dev/null || true
    rm -rf /var/lib/ollama 2>/dev/null || true
    rm -rf "${HOME}/.ollama" 2>/dev/null || true
    # Also clean up for the sudo-invoking user
    if [[ -n "${SUDO_USER:-}" ]]; then
      local_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
      rm -rf "${local_home}/.ollama" 2>/dev/null || true
    fi
    userdel ollama 2>/dev/null || true
    groupdel ollama 2>/dev/null || true
  fi

  # Remove Claude Code
  if command -v claude &>/dev/null; then
    info "Removing Claude Code..."
    npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
  fi

  # Remove OpenCode
  if [[ -f /usr/local/bin/opencode ]]; then
    info "Removing OpenCode..."
    rm -f /usr/local/bin/opencode
  fi

  # Remove uv
  if command -v uv &>/dev/null; then
    info "Removing uv..."
    rm -f "$(command -v uv)" 2>/dev/null || true
    rm -rf "${HOME}/.cargo/bin/uv" 2>/dev/null || true
    if [[ -n "${SUDO_USER:-}" ]]; then
      local_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
      rm -f "${local_home}/.cargo/bin/uv" 2>/dev/null || true
    fi
  fi

  success "Cleanup complete. Removed: Ollama (+ all models), Claude Code, OpenCode, uv."
  info "Node.js was NOT removed (may be used by other tools)."
  exit 0
fi

# ------------------------------------------------------------------------------
# System detection
# ------------------------------------------------------------------------------
header "System detection"

GPU_VRAM_MB=0
GPU_NAME="none"
if command -v nvidia-smi &>/dev/null; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 || echo "unknown")
  GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 || echo "0")
  info "GPU: $GPU_NAME  |  VRAM: ${GPU_VRAM_MB}MiB"
else
  warn "nvidia-smi not found — GPU acceleration will not be available for Ollama"
fi

RAM_GB=$(awk '/MemTotal/ { printf "%d", $2/1024/1024 }' /proc/meminfo)
info "RAM: ${RAM_GB}GB"
info "CPU cores: $(nproc)"

# Decide which models fit in GPU (rough Q4_K_M sizing: 0.55 GB per B params)
# A10 has 23 GB — models up to ~40B can partially offload; up to ~32B fit fully.

# ------------------------------------------------------------------------------
# Check section
# ------------------------------------------------------------------------------
if [[ "$CHECK_ONLY" == "true" ]]; then
  header "Tools that would be installed"
  echo "  • Ollama        (always latest — installer is idempotent)"
  echo "  • Node.js 22.x  (via NodeSource, prerequisite for Claude Code)"
  echo "  • Claude Code   (npm install -g @anthropic-ai/claude-code)"
  echo "  • OpenCode      (latest release from github.com/sst/opencode)"
  echo ""
  header "Models that would be pulled"
  echo "  Pipeline models: from adb/.env (OLLAMA_VISION_MODEL, OLLAMA_TEXT_MODEL,"
  echo "                   local LLM_* entries) via adb/pull-ollama-models.sh"
  echo "  Extra dev/coding models:"
  echo "  • qwen2.5-coder:32b    ~20GB  (best coding, fits in A10 GPU)"
  echo "  • devstral             ~15GB  (Mistral coding, GPU)"
  echo "  • mistral-small3.1:24b ~14GB  (fast exploration, GPU)"
  echo "  • deepseek-r1:32b      ~20GB  (reasoning/code review, GPU)"
  echo ""
  info "Total pull size: ~126GB — ensure disk space is available"
  exit 0
fi

# ==============================================================================
# TOOL INSTALLATION
# ==============================================================================

if [[ "$MODELS_ONLY" == "false" ]]; then

  # ---- Ollama ----------------------------------------------------------------
  header "Installing Ollama"

  # Always run the Ollama installer — it is idempotent and self-updates to
  # the latest release, so we don't need to track a minimum version here.
  # Keeping a pinned floor would prevent upgrades (e.g. 0.28.x → 0.30.x).
  info "Running Ollama installer (installs or upgrades to latest)..."
  curl -fsSL https://ollama.com/install.sh | sh

  # Verify
  OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
  success "Ollama $OLLAMA_VER installed"

  # Check NVIDIA driver meets CUDA 12.8 requirement for this Ollama version.
  # Ollama 0.28+ ships libcudart 12.8 which requires driver series >= 570.
  OLLAMA_MIN_CUDA_DRIVER=570
  if command -v nvidia-smi &>/dev/null; then
    CURRENT_GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader \
      | grep -oP '^\d+' | head -1 || echo "0")
    if [[ "$CURRENT_GPU_DRIVER" -lt "$OLLAMA_MIN_CUDA_DRIVER" ]]; then
      echo ""
      warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      warn "NVIDIA driver ${CURRENT_GPU_DRIVER} is TOO OLD for Ollama ${OLLAMA_VER}."
      warn "Ollama 0.28+ requires CUDA 12.8 — needs driver >= ${OLLAMA_MIN_CUDA_DRIVER}."
      warn "GPU acceleration will fail until the driver is upgraded."
      warn ""
      warn "Fix: sudo ./nvidia-gpu-setup.sh   (will install driver 595-server)"
      warn "A reboot is required after the driver upgrade."
      warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
    else
      success "NVIDIA driver ${CURRENT_GPU_DRIVER} meets Ollama CUDA 12.8 requirement (>= ${OLLAMA_MIN_CUDA_DRIVER})"
    fi
  fi

  # Ensure Ollama systemd service is enabled and running
  if systemctl is-enabled ollama &>/dev/null 2>&1; then
    systemctl enable --now ollama
    success "Ollama service enabled and started"
  else
    # Ollama may not install a service on all setups; start manually if needed
    if ! pgrep -x ollama &>/dev/null; then
      info "Starting Ollama in background..."
      OLLAMA_HOST=0.0.0.0 nohup ollama serve >/var/log/ollama.log 2>&1 &
      sleep 3
    fi
  fi

  # Configure Ollama to use all GPU layers and expose on all interfaces
  # (useful for accessing from other containers/VMs)
  OLLAMA_ENV_FILE="/etc/systemd/system/ollama.service.d/override.conf"
  if [[ -f /etc/systemd/system/ollama.service ]]; then
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > "$OLLAMA_ENV_FILE" <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_NUM_PARALLEL=4"
Environment="OLLAMA_KEEP_ALIVE=24h"
EOF
    systemctl daemon-reload
    systemctl restart ollama
    success "Ollama systemd override written: $OLLAMA_ENV_FILE"
  fi

  # ---- Node.js (prerequisite for Claude Code) --------------------------------
  header "Installing Node.js 22.x"

  if command -v node &>/dev/null; then
    NODE_VER=$(node --version)
    NODE_MAJOR=$(echo "$NODE_VER" | grep -oP '\d+' | head -1)
    if [[ "$NODE_MAJOR" -ge 20 ]]; then
      success "Node.js $NODE_VER already installed"
    else
      warn "Node.js $NODE_VER found but < 20 — upgrading via NodeSource"
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs
    fi
  else
    info "Installing Node.js 22.x via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    success "Node.js $(node --version) installed"
  fi

  # ---- Claude Code -----------------------------------------------------------
  header "Installing Claude Code"

  if command -v claude &>/dev/null; then
    success "Claude Code already installed: $(claude --version 2>/dev/null || echo 'version unknown')"
    info "Upgrading to latest..."
    npm install -g @anthropic-ai/claude-code
  else
    info "Installing Claude Code globally via npm..."
    npm install -g @anthropic-ai/claude-code
    success "Claude Code installed: $(claude --version 2>/dev/null || echo 'ok')"
  fi

  # ---- OpenCode --------------------------------------------------------------
  header "Installing OpenCode"

  install_opencode() {
    info "Fetching latest OpenCode release..."
    # sst/opencode redirects to anomalyco/opencode for release assets
    RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/sst/opencode/releases/latest)
    LATEST_TAG=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
    info "Latest OpenCode tag: $LATEST_TAG"

    # Detect arch and pick the correct tarball asset
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  ARCH_LABEL="linux-x64" ;;
      aarch64) ARCH_LABEL="linux-arm64" ;;
      *)       die "Unsupported architecture for OpenCode: $ARCH" ;;
    esac

    # Assets are tarballs, e.g. opencode-linux-x64.tar.gz
    ASSET_NAME="opencode-${ARCH_LABEL}.tar.gz"
    ASSET_EXACT="opencode-${ARCH_LABEL}.tar.gz"
    ASSET_BASELINE="opencode-${ARCH_LABEL}-baseline.tar.gz"
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assets = {a['name']: a['browser_download_url'] for a in data.get('assets', [])}
exact    = '${ASSET_EXACT}'
baseline = '${ASSET_BASELINE}'
url = assets.get(exact) or assets.get(baseline)
if not url:
    sys.stderr.write('Asset not found. Available: ' + ', '.join(assets.keys()) + '\n')
    sys.exit(1)
print(url)
")

    info "Downloading $ASSET_NAME..."
    TMPDIR_OC=$(mktemp -d)
    curl -fsSL "$DOWNLOAD_URL" -o "${TMPDIR_OC}/${ASSET_NAME}"
    tar -xzf "${TMPDIR_OC}/${ASSET_NAME}" -C "$TMPDIR_OC"

    # The binary inside the tarball is named 'opencode'
    BINARY=$(find "$TMPDIR_OC" -type f -name "opencode" | head -1)
    [[ -n "$BINARY" ]] || die "Could not find 'opencode' binary inside tarball"

    install -m 755 "$BINARY" /usr/local/bin/opencode
    rm -rf "$TMPDIR_OC"
    success "OpenCode $LATEST_TAG installed at /usr/local/bin/opencode"
  }

  if command -v opencode &>/dev/null; then
    success "OpenCode already installed: $(opencode --version 2>/dev/null || echo 'version unknown')"
    info "Re-installing to ensure latest version..."
    install_opencode
  else
    install_opencode
  fi

  # ---- Additional useful tools -----------------------------------------------
  header "Installing supporting tools"

  apt-get install -y --no-install-recommends \
    curl wget git jq python3 python3-pip \
    build-essential ca-certificates gnupg 2>/dev/null || true

  # Install uv (fast Python package manager, used by many AI tools)
  if ! command -v uv &>/dev/null; then
    info "Installing uv (fast Python package manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    success "uv installed"
  else
    success "uv already installed"
  fi

  success "All tools installed"

fi  # end MODELS_ONLY guard

# ==============================================================================
# MODEL PULLS
# ==============================================================================

if [[ "$SKIP_MODELS" == "false" ]]; then

  header "Waiting for Ollama to be ready"

  OLLAMA_URL="${OLLAMA_HOST:-http://localhost}:${OLLAMA_PORT:-11434}"

  for i in $(seq 1 30); do
    if curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null; then
      success "Ollama API is ready"
      break
    fi
    if [[ $i -eq 30 ]]; then
      die "Ollama did not become ready after 30 seconds. Check: journalctl -u ollama"
    fi
    info "Waiting... ($i/30)"
    sleep 1
  done

  # ---------------------------------------------------------------------------
  # Model catalogue
  #
  # Format: "model_tag|description|approx_size|runs_on"
  # runs_on: gpu | cpu | gpu-partial
  # ---------------------------------------------------------------------------

  # NOTE: the APEX app's *pipeline* models (vision + text + local LLM_* servers)
  # are NOT listed here — they are pulled from .env by adb/pull-ollama-models.sh
  # (single source of truth; see the delegated call after this loop). This list is
  # only the extra developer/coding models for the workstation.
  declare -A MODEL_DESC=(
    ["qwen2.5-coder:32b"]="Qwen 2.5 Coder 32B — BEST CODING, fits fully in A10 GPU at Q4"
    ["devstral"]="Mistral Devstral — dedicated coding model, fast on GPU"
    ["mistral-small3.1:24b"]="Mistral Small 3.1 24B — fast exploration/Q&A, GPU"
    ["deepseek-r1:32b"]="DeepSeek R1 32B — reasoning + code review, fits in GPU"
  )

  MODELS=(
    "qwen2.5-coder:32b"
    "devstral"
    "mistral-small3.1:24b"
    "deepseek-r1:32b"
  )

  header "Pulling models"
  echo ""
  echo "  Hardware profile:"
  echo "    GPU: $GPU_NAME (${GPU_VRAM_MB}MiB VRAM)"
  echo "    RAM: ${RAM_GB}GB"
  echo ""
  echo "  Model plan (extra dev/coding models; pipeline models come from .env):"
  echo "    qwen2.5-coder:32b   → GPU (fits ~20GB at Q4)"
  echo "    devstral            → GPU (~15GB at Q4)"
  echo "    mistral-small3.1:24b→ GPU (~14GB at Q4)"
  echo "    deepseek-r1:32b     → GPU (~20GB at Q4)"
  echo ""

  FAILED_MODELS=()

  for model in "${MODELS[@]}"; do
    desc="${MODEL_DESC[$model]:-$model}"
    header "Pulling: $model"
    info "$desc"
    if ollama pull "$model"; then
      success "Pulled: $model"
    else
      warn "Failed to pull $model — skipping (check model name on https://ollama.com/library)"
      FAILED_MODELS+=("$model")
    fi
    echo ""
  done

  # ---------------------------------------------------------------------------
  # Pipeline models — pulled from .env (single source of truth), so the
  # exact tags the APEX AI service and vision pipeline reference are guaranteed
  # present with matching names (fixes the old hardcoded gemma4:27b vs config
  # gemma4:26b drift). Delegated to adb/pull-ollama-models.sh.
  # ---------------------------------------------------------------------------
  _AI_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
  _PULL_SCRIPT="$_AI_SCRIPT_DIR/../adb/pull-ollama-models.sh"
  if [[ -x "$_PULL_SCRIPT" ]]; then
    header "Pulling APEX app pipeline models (from .env)"
    if ! "$_PULL_SCRIPT"; then
      warn "One or more pipeline models failed to pull — see above."
      FAILED_MODELS+=("(pipeline models from .env)")
    fi
  else
    warn "Pipeline model puller not found at $_PULL_SCRIPT — skipping."
    warn "Pipeline LLM/vision models from .env were NOT pulled."
  fi

  # ---------------------------------------------------------------------------
  # Summary
  # ---------------------------------------------------------------------------
  header "Model pull summary"
  ollama list

  if [[ ${#FAILED_MODELS[@]} -gt 0 ]]; then
    warn "The following models failed to pull:"
    for m in "${FAILED_MODELS[@]}"; do
      echo "    • $m"
    done
    echo ""
    warn "Check model names at: https://ollama.com/library"
  fi

fi  # end SKIP_MODELS guard

# ==============================================================================
# Usage guide
# ==============================================================================
header "Quick-start guide"

cat <<'GUIDE'

  Ollama
  ------
  ollama run qwen2.5-coder:32b          # best coding (GPU)
  ollama run devstral                   # Mistral coding (GPU)
  ollama run deepseek-r1:32b            # reasoning/review (GPU)
  ollama run mistral-small3.1:24b       # fast Q&A / exploration (GPU)
  # Pipeline models (names come from adb/.env), e.g.:
  ollama run llama3.3:70b               # summarisation (CPU RAM)
  ollama run gemma4:26b                 # vision + general (GPU)
  ollama list                           # list installed models
  ollama ps                             # show running models

  Claude Code
  -----------
  claude                                # start Claude Code REPL
  claude --help

  OpenCode
  --------
  opencode                              # launch TUI in current directory
  opencode --help

  Ollama API
  ----------
  curl http://localhost:11434/api/generate -d '{
    "model": "qwen2.5-coder:32b",
    "prompt": "Write a Python function to reverse a linked list"
  }'

  Configure Claude Code to use Ollama
  ------------------------------------
  # In your project, add to .claude/settings.json:
  # {
  #   "env": {
  #     "ANTHROPIC_BASE_URL": "http://localhost:11434/v1"
  #   }
  # }
  # Note: Ollama's /v1 endpoint is OpenAI-compatible, not Anthropic-API-compatible.
  # Use OpenCode with Ollama for local model integration (it supports Ollama natively).

GUIDE

success "Setup complete!"
