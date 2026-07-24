#!/usr/bin/env bash
# Install a self-contained PowerShell 7 for Linux without root.
# Idempotent: if already installed, just prints the path and exits 0.
# On success the LAST line printed is "PWSH=<abs-path-to-pwsh>" for easy capture.
set -euo pipefail

PWSH_VERSION="${PWSH_VERSION:-7.4.6}"
CACHE_DIR="${PWSH_CACHE_DIR:-$HOME/.cache/pwsh-$PWSH_VERSION}"
PWSH_BIN="$CACHE_DIR/pwsh"

if [ -x "$PWSH_BIN" ]; then
    echo "PowerShell $PWSH_VERSION already present." >&2
    echo "PWSH=$PWSH_BIN"
    exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  PKG_ARCH="x64" ;;
    aarch64|arm64) PKG_ARCH="arm64" ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

URL="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${PKG_ARCH}.tar.gz"
TMP_TGZ="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$TMP_TGZ"' EXIT

echo "Downloading PowerShell $PWSH_VERSION ($PKG_ARCH)..." >&2
if ! curl -fsSL --retry 3 -o "$TMP_TGZ" "$URL"; then
    echo "Download failed. If this is a network-policy block, check the environment's" >&2
    echo "egress policy (see the remote-environment docs) rather than retrying blindly." >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
tar -xzf "$TMP_TGZ" -C "$CACHE_DIR"
chmod +x "$PWSH_BIN"

# Sanity check.
VER="$("$PWSH_BIN" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || true)"
if [ -z "$VER" ]; then
    echo "Extracted pwsh did not run." >&2
    exit 1
fi
echo "Installed PowerShell $VER at $PWSH_BIN" >&2
echo "PWSH=$PWSH_BIN"
