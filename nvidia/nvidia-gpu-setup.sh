#!/usr/bin/env bash
# ==============================================================================
# nvidia-gpu-setup.sh
# NVIDIA GPU driver setup for Ubuntu 24.04 on Oracle OCI (oracle kernel flavour)
#
# Usage:
#   sudo ./nvidia-gpu-setup.sh [OPTIONS]
#
# Options:
#   --check-only    Detect GPU/kernel info and show what would be installed
#   --skip-reboot   Do not prompt to reboot after install
#   --cleanup       Remove NVIDIA drivers, utils, and nvtop (reboot required)
#   --help          Show this help message
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colours
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
header()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}"; }

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
CHECK_ONLY=false
SKIP_REBOOT=false
DO_CLEANUP=false

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --check-only)   CHECK_ONLY=true ;;
    --skip-reboot)  SKIP_REBOOT=true ;;
    --cleanup)      DO_CLEANUP=true ;;
    --help|-h)
      sed -n '/^# Usage/,/^# ====/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Root check
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

# ------------------------------------------------------------------------------
# Cleanup — remove NVIDIA packages this script installs
# ------------------------------------------------------------------------------
if [[ "$DO_CLEANUP" == "true" ]]; then
  header "Removing NVIDIA drivers and utilities"

  # Find all installed nvidia/cuda packages
  NVIDIA_PKGS=$(dpkg -l 2>/dev/null | grep -E 'nvidia-|cuda-|libnvidia-' | awk '{print $2}' || true)
  if [[ -n "$NVIDIA_PKGS" ]]; then
    info "Removing packages: $(echo "$NVIDIA_PKGS" | tr '\n' ' ')"
    apt-get purge -y $NVIDIA_PKGS || warn "Some packages could not be purged"
    apt-get autoremove -y
  else
    info "No NVIDIA packages found to remove."
  fi

  # Remove nvtop
  if dpkg -l nvtop 2>/dev/null | grep -q '^ii'; then
    info "Removing nvtop..."
    apt-get purge -y nvtop
  fi

  # Remove modules-load config
  if [[ -f /etc/modules-load.d/nvidia.conf ]]; then
    info "Removing /etc/modules-load.d/nvidia.conf"
    rm -f /etc/modules-load.d/nvidia.conf
  fi

  success "NVIDIA cleanup complete."
  warn "A reboot is required to fully unload the kernel modules."
  if ! $SKIP_REBOOT; then
    read -r -t 30 -p "Reboot now? [y/N] " REBOOT_ANSWER || REBOOT_ANSWER="n"
    if [[ "${REBOOT_ANSWER,,}" == "y" ]]; then
      reboot
    fi
  fi
  exit 0
fi

# ==============================================================================
# 1. DETECT ENVIRONMENT
# ==============================================================================
header "Detecting environment"

KERNEL=$(uname -r)
info "Kernel: $KERNEL"

# Detect kernel flavour (e.g. oracle, generic, aws)
KERNEL_FLAVOUR=$(echo "$KERNEL" | grep -oP '(?<=-)[a-z]+$' || true)
if [[ -z "$KERNEL_FLAVOUR" ]]; then
  KERNEL_FLAVOUR="generic"
fi
info "Kernel flavour: $KERNEL_FLAVOUR"

# Detect kernel major.minor version for package selection
KERNEL_VERSION=$(echo "$KERNEL" | grep -oP '^\d+\.\d+')
info "Kernel version: $KERNEL_VERSION"

# Detect NVIDIA GPU via lspci
GPU_INFO=$(lspci 2>/dev/null | grep -i nvidia || true)
if [[ -z "$GPU_INFO" ]]; then
  error "No NVIDIA GPU detected via lspci. Exiting."
  exit 1
fi
info "GPU detected: $GPU_INFO"

# Check if nvidia module is already loaded
if lsmod | grep -q '^nvidia '; then
  DRIVER_LOADED=true
else
  DRIVER_LOADED=false
fi

# Check if nvidia-smi works
if nvidia-smi &>/dev/null; then
  SMI_WORKS=true
else
  SMI_WORKS=false
fi

# ------------------------------------------------------------------------------
# Determine driver series to use (prefer already-installed series)
# ------------------------------------------------------------------------------
DRIVER_SERIES=""
for series in 535 525 515; do
  if dpkg -l "nvidia-utils-${series}-server" 2>/dev/null | grep -q '^ii'; then
    DRIVER_SERIES="${series}-server"
    break
  fi
  if dpkg -l "nvidia-utils-${series}" 2>/dev/null | grep -q '^ii'; then
    DRIVER_SERIES="${series}"
    break
  fi
done

# Fall back to 535-server as the default for OCI GPU instances
if [[ -z "$DRIVER_SERIES" ]]; then
  DRIVER_SERIES="535-server"
  warn "No existing NVIDIA utils found; defaulting to driver series: $DRIVER_SERIES"
else
  info "Detected installed driver series: $DRIVER_SERIES"
fi

# Build candidate package names
MODULES_PKG="linux-modules-nvidia-${DRIVER_SERIES}-${KERNEL_FLAVOUR}-${KERNEL_VERSION}"
DKMS_PKG="nvidia-dkms-${DRIVER_SERIES}"

# Check which packages exist in apt
check_pkg_available() {
  apt-cache show "$1" &>/dev/null
}

if check_pkg_available "$MODULES_PKG"; then
  INSTALL_METHOD="prebuilt"
  info "Pre-built kernel modules package available: $MODULES_PKG"
elif check_pkg_available "$DKMS_PKG"; then
  INSTALL_METHOD="dkms"
  warn "No pre-built package for this kernel; will use DKMS: $DKMS_PKG"
else
  error "Could not find a suitable kernel modules package."
  error "Tried: $MODULES_PKG (prebuilt) and $DKMS_PKG (DKMS)"
  error "You may need to install a newer driver or check your apt sources."
  exit 1
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
header "Installation plan"
echo "  Kernel         : $KERNEL"
echo "  Kernel flavour : $KERNEL_FLAVOUR"
echo "  Driver series  : $DRIVER_SERIES"
echo "  Install method : $INSTALL_METHOD"
if [[ $INSTALL_METHOD == "prebuilt" ]]; then
  echo "  Package        : $MODULES_PKG"
else
  echo "  Package        : $DKMS_PKG"
fi
echo "  Driver loaded  : $DRIVER_LOADED"
echo "  nvidia-smi OK  : $SMI_WORKS"

if $CHECK_ONLY; then
  info "--check-only requested; exiting without making changes."
  exit 0
fi

if $SMI_WORKS && $DRIVER_LOADED; then
  success "NVIDIA driver is already loaded and nvidia-smi is working."
  success "Nothing to install."
  exit 0
fi

# ==============================================================================
# 2. UPDATE APT
# ==============================================================================
header "Updating apt package index"
apt-get update -q

# ==============================================================================
# 3. INSTALL DRIVER / KERNEL MODULES
# ==============================================================================
header "Installing NVIDIA kernel modules"

if [[ $INSTALL_METHOD == "prebuilt" ]]; then
  info "Installing pre-built modules: $MODULES_PKG"
  apt-get install -y "$MODULES_PKG"
else
  # DKMS path — needs kernel headers
  HEADERS_PKG="linux-headers-${KERNEL}"
  info "Installing kernel headers: $HEADERS_PKG"
  apt-get install -y "$HEADERS_PKG" || warn "Kernel headers package not found; DKMS build may fail."

  info "Installing DKMS package: $DKMS_PKG"
  apt-get install -y dkms "$DKMS_PKG"
fi

# Also ensure the base driver utilities are present
UTILS_PKG="nvidia-utils-${DRIVER_SERIES}"
if ! dpkg -l "$UTILS_PKG" 2>/dev/null | grep -q '^ii'; then
  info "Installing driver utilities: $UTILS_PKG"
  apt-get install -y "$UTILS_PKG"
else
  success "Driver utilities already installed: $UTILS_PKG"
fi

# nvtop for monitoring
if ! command -v nvtop &>/dev/null; then
  info "Installing nvtop (GPU monitor)"
  apt-get install -y nvtop
else
  success "nvtop already installed: $(nvtop --version 2>/dev/null | head -1 || true)"
fi

# ==============================================================================
# 4. LOAD MODULE
# ==============================================================================
header "Loading NVIDIA kernel module"

if lsmod | grep -q '^nvidia '; then
  success "nvidia module already loaded."
else
  if modprobe nvidia 2>/dev/null; then
    success "nvidia module loaded successfully."
  else
    warn "modprobe nvidia failed — a reboot may be required to load the new modules."
  fi
fi

# Also load nvidia-uvm and nvidia-modeset if available (needed for CUDA)
for mod in nvidia_uvm nvidia_modeset; do
  modprobe "$mod" 2>/dev/null && info "Loaded module: $mod" || true
done

# ==============================================================================
# 5. VERIFY
# ==============================================================================
header "Verifying installation"

if nvidia-smi; then
  success "nvidia-smi is working correctly."
  INSTALL_SUCCESS=true
else
  warn "nvidia-smi still not working — a reboot is likely required."
  INSTALL_SUCCESS=false
fi

# ==============================================================================
# 6. PERSIST MODULE LOAD ON BOOT
# ==============================================================================
header "Ensuring NVIDIA modules load on boot"

MODULES_LOAD_FILE="/etc/modules-load.d/nvidia.conf"
if [[ ! -f "$MODULES_LOAD_FILE" ]]; then
  cat > "$MODULES_LOAD_FILE" <<'EOF'
# NVIDIA modules — loaded at boot
nvidia
nvidia_uvm
nvidia_modeset
EOF
  success "Created $MODULES_LOAD_FILE"
else
  success "$MODULES_LOAD_FILE already exists."
fi

# ==============================================================================
# 7. PRINT MONITORING CHEATSHEET
# ==============================================================================
header "GPU monitoring commands"
cat <<'EOF'
  # One-shot status
  nvidia-smi

  # Live refresh every 1 second
  watch -n 1 nvidia-smi

  # Continuous CSV log (timestamp, GPU%, MEM%, mem used, mem total, temp, power)
  nvidia-smi --query-gpu=timestamp,utilization.gpu,utilization.memory,\
memory.used,memory.total,temperature.gpu,power.draw \
    --format=csv -l 1

  # Log to file
  nvidia-smi --query-gpu=timestamp,utilization.gpu,utilization.memory,\
memory.used,memory.total,temperature.gpu,power.draw \
    --format=csv -l 1 | tee gpu_stats.csv

  # Interactive TUI (htop-style)
  nvtop

  # Query specific GPU properties
  nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap \
    --format=csv,noheader
EOF

# ==============================================================================
# 8. REBOOT PROMPT
# ==============================================================================
if ! $INSTALL_SUCCESS && ! $SKIP_REBOOT; then
  echo
  warn "The NVIDIA driver is installed but the kernel module could not be loaded."
  warn "A reboot is required to activate the driver."
  read -r -t 30 -p "Reboot now? [y/N] " REBOOT_ANSWER || REBOOT_ANSWER="n"
  if [[ "${REBOOT_ANSWER,,}" == "y" ]]; then
    info "Rebooting..."
    reboot
  else
    info "Skipping reboot. Run 'sudo reboot' when ready, then verify with: nvidia-smi"
  fi
elif $INSTALL_SUCCESS; then
  echo
  success "Setup complete — NVIDIA GPU is ready to use."
fi
