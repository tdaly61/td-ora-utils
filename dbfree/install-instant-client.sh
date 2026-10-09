#!/usr/bin/env bash
# install-instant-client.sh — one-time (idempotent) Oracle Instant Client
# install. Installs to ~/oraclient/<INSTANT_CLIENT>; skipped if that
# directory already exists.
#
# Usage: ./install-instant-client.sh   (normally called by setup-for-dbfree.sh)

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib.sh"

ORACLE_CLIENT_DIR="$HOME/oraclient"
INSTANT_CLIENT="$(resolve_instant_client)"
[ -n "$INSTANT_CLIENT" ] || die "INSTANT_CLIENT/INSTANT_CLIENT_MAC not set in dbfree/.env (see .env.sample)."

if [ -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ]; then
    ok "Oracle Instant Client already installed at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT — skipping."
    exit 0
fi

BASIC_ZIP="$(platform_val BASIC_ZIP)"
SQLPLUS_ZIP="$(platform_val SQLPLUS_ZIP)"
BASIC_URL="$(platform_val BASIC_URL)"
SQLPLUS_URL="$(platform_val SQLPLUS_URL)"
for v in BASIC_ZIP SQLPLUS_ZIP BASIC_URL SQLPLUS_URL; do
    [ -n "${!v}" ] || die "$v not set in dbfree/.env for this platform (see .env.sample)."
done

mkdir -p "$ORACLE_CLIENT_DIR"

hdr "Installing Oracle Instant Client ($INSTANT_CLIENT)"

if [ "$PLATFORM" = "darwin" ]; then
    # macOS ships the Instant Client as DMGs, each containing install_ic.sh.
    _install_dmg() {
        local dmg="$1" label vol rc
        label=$(basename "$dmg" .dmg)
        echo "  Mounting $label..."
        vol=$(hdiutil attach -nobrowse "$dmg" 2>/dev/null | awk '/\/Volumes\// {print $NF; exit}')
        [ -n "$vol" ] && [ -d "$vol" ] || die "Failed to mount $dmg."
        echo "  Mounted at $vol — running install_ic.sh..."
        (cd "$vol" && sh ./install_ic.sh) 2>&1
        rc=$?
        hdiutil detach "$vol" 2>/dev/null || true
        [ "$rc" -eq 0 ] || die "install_ic.sh failed for $label (exit $rc)."
    }

    basic_dmg="$ORACLE_CLIENT_DIR/$BASIC_ZIP"
    sqlplus_dmg="$ORACLE_CLIENT_DIR/$SQLPLUS_ZIP"
    default_ic_dir="$HOME/Downloads/$INSTANT_CLIENT"

    echo "  Downloading Instant Client Basic..."
    curl -fL -o "$basic_dmg" "$BASIC_URL" || die "Download failed: $BASIC_URL"
    echo "  Downloading Instant Client SQL*Plus..."
    curl -fL -o "$sqlplus_dmg" "$SQLPLUS_URL" || die "Download failed: $SQLPLUS_URL"

    [ -d "$default_ic_dir" ] && rm -rf "$default_ic_dir"
    _install_dmg "$basic_dmg"
    _install_dmg "$sqlplus_dmg"
    [ -d "$default_ic_dir" ] || die "install_ic.sh did not create $default_ic_dir as expected."

    mv "$default_ic_dir" "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    [ -f "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT/sqlplus" ] || die "sqlplus not found after install under $ORACLE_CLIENT_DIR/$INSTANT_CLIENT."
    rm -f "$basic_dmg" "$sqlplus_dmg"

    oracle_home="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
    shell_rc="$HOME/.zshrc"
    # Deliberately NOT exporting TNS_ADMIN here — dbfree uses plain
    # EZConnect, no wallet, and dbfree/lib.sh's sqlplus_setup_env() explicitly clears
    # TNS_ADMIN before every sqlplus call for exactly this reason.
    grep -q "export ORACLE_HOME=$oracle_home" "$shell_rc" 2>/dev/null || echo "export ORACLE_HOME=$oracle_home" >> "$shell_rc"
    grep -q "export DYLD_LIBRARY_PATH=$oracle_home" "$shell_rc" 2>/dev/null || echo "export DYLD_LIBRARY_PATH=$oracle_home" >> "$shell_rc"
    grep -q "export PATH=$oracle_home:\$PATH" "$shell_rc" 2>/dev/null || echo "export PATH=$oracle_home:\$PATH" >> "$shell_rc"
else
    # Linux ships the Instant Client as plain ZIPs.
    if ! command -v unzip &>/dev/null; then
        echo "  unzip not found — installing (needs sudo)..."
        sudo apt-get update -y && sudo apt-get install -y unzip
    fi

    basic_zip="$ORACLE_CLIENT_DIR/$BASIC_ZIP"
    sqlplus_zip="$ORACLE_CLIENT_DIR/$SQLPLUS_ZIP"

    echo "  Downloading Instant Client Basic..."
    curl -fL -o "$basic_zip" "$BASIC_URL" || die "Download failed: $BASIC_URL"
    echo "  Downloading Instant Client SQL*Plus..."
    curl -fL -o "$sqlplus_zip" "$SQLPLUS_URL" || die "Download failed: $SQLPLUS_URL"
    unzip -o "$basic_zip" -d "$ORACLE_CLIENT_DIR" >/dev/null
    unzip -o "$sqlplus_zip" -d "$ORACLE_CLIENT_DIR" >/dev/null
    rm -f "$basic_zip" "$sqlplus_zip"
    [ -d "$ORACLE_CLIENT_DIR/$INSTANT_CLIENT" ] || die "Oracle Instant Client not found at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT after extracting — Oracle may have changed the zip layout."

    oracle_home="$ORACLE_CLIENT_DIR/$INSTANT_CLIENT"

    # Ubuntu 24+ renamed the libaio package/library; older releases use the
    # original names. Needs sudo; everything else in this script doesn't.
    ubuntu_ver="$(lsb_release -rs 2>/dev/null | cut -d. -f1 || echo 0)"
    if [ "$ubuntu_ver" -ge 24 ] 2>/dev/null; then
        sudo apt-get install -y libaio1t64
        libaio_target="/usr/lib/x86_64-linux-gnu/libaio.so.1t64"
    else
        sudo apt-get install -y libaio1
        libaio_target="/usr/lib/x86_64-linux-gnu/libaio.so.1.0.1"
    fi
    libaio_link="/usr/lib/x86_64-linux-gnu/libaio.so.1"
    if [ ! -e "$libaio_link" ] || [ "$(readlink "$libaio_link")" != "$libaio_target" ]; then
        echo "  Fixing libaio.so.1 symlink -> $libaio_target (needs sudo)..."
        sudo ln -sf "$libaio_target" "$libaio_link"
    fi

    shell_rc="$HOME/.bashrc"
    grep -q "export ORACLE_HOME=$oracle_home" "$shell_rc" 2>/dev/null || echo "export ORACLE_HOME=$oracle_home" >> "$shell_rc"
    grep -q "export LD_LIBRARY_PATH=$oracle_home" "$shell_rc" 2>/dev/null || echo "export LD_LIBRARY_PATH=$oracle_home" >> "$shell_rc"
    grep -q "export PATH=$oracle_home:\$PATH" "$shell_rc" 2>/dev/null || echo "export PATH=$oracle_home:\$PATH" >> "$shell_rc"
fi

ok "Oracle Instant Client installed at $ORACLE_CLIENT_DIR/$INSTANT_CLIENT"
