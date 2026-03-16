#!/usr/bin/env bash
# Run OFFLINE on macOS. Installs from cache/macos/ (no network required).
# Usage: ./install-from-cache-macos.sh [--profile <name>]
# Run from the multi-platform-offline-cache folder (e.g. from USB). Profile is optional.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$MP_ROOT/cache/macos"
META_DIR="$CACHE_DIR/meta"

if [[ ! -d "$CACHE_DIR" ]]; then
  echo "Error: cache/macos not found at $CACHE_DIR. Copy the full multi-platform-offline-cache folder (including cache/) to this machine." >&2
  exit 1
fi

[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
[[ -x /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_section() { echo ""; echo "===== $* ====="; }

if [[ -f "$CACHE_DIR/SHA256SUMS" ]]; then
  log_section "Verifying checksums (optional)"
  (cd "$CACHE_DIR" && shasum -a 256 -c SHA256SUMS 2>/dev/null) || log_warn "Some checksums failed; continuing."
fi

log_section "Installing from macOS offline cache"

# 1. Homebrew
if command -v brew >/dev/null 2>&1 && [[ -d "$CACHE_DIR/brew" ]]; then
  log_section "Homebrew: installing from cache"
  export HOMEBREW_CACHE="$CACHE_DIR/brew"
  if [[ -f "$META_DIR/brew-packages.txt" ]]; then
    while IFS= read -r pkg; do
      [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
      brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
    done < "$META_DIR/brew-packages.txt"
  fi
  if [[ -f "$META_DIR/brew-casks.txt" ]]; then
    while IFS= read -r cask; do
      [[ -z "$cask" || "$cask" =~ ^# ]] && continue
      brew list --cask "$cask" >/dev/null 2>&1 || brew install --cask "$cask"
    done < "$META_DIR/brew-casks.txt"
  fi
  unset HOMEBREW_CACHE
fi

# 2. Pip user
if [[ -d "$CACHE_DIR/pip/wheelhouse" && -f "$CACHE_DIR/pip/pip-user-freeze.txt" ]] && command -v python3 >/dev/null 2>&1; then
  log_section "Pip user: installing from cache"
  python3 -m pip install --user --no-index --find-links "$CACHE_DIR/pip/wheelhouse" -r "$CACHE_DIR/pip/pip-user-freeze.txt" || log_warn "Some pip user packages failed"
fi

# 3. Pipx
if command -v pipx >/dev/null 2>&1 && [[ -f "$META_DIR/pipx-packages.txt" ]]; then
  log_section "Pipx: installing from cache"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    pipx list --short 2>/dev/null | grep -Fxq "$app" && continue
    whl="$(ls "$CACHE_DIR/pipx/"*"${app}"*.whl "$CACHE_DIR/pipx/${app}"*.whl 2>/dev/null | head -1)"
    [[ -n "$whl" && -f "$whl" ]] && pipx install "$whl" || log_warn "No wheel for: $app"
  done < "$META_DIR/pipx-packages.txt"
fi

# 4. UV
if command -v uv >/dev/null 2>&1 && [[ -f "$META_DIR/uv-tools.txt" ]]; then
  log_section "UV: installing from cache"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    uv tool list 2>/dev/null | awk '{print $1}' | grep -Fxq "$app" && continue
    whl="$(ls "$CACHE_DIR/uv/"*"${app}"*.whl "$CACHE_DIR/uv/${app}"*.whl 2>/dev/null | head -1)"
    [[ -n "$whl" && -f "$whl" ]] && uv tool install "$whl" || log_warn "No wheel for uv: $app"
  done < "$META_DIR/uv-tools.txt"
fi

# 5. NPM
if command -v npm >/dev/null 2>&1 && ls "$CACHE_DIR/npm/"*.tgz >/dev/null 2>&1; then
  log_section "NPM: installing from cache"
  for tgz in "$CACHE_DIR/npm/"*.tgz; do
    [[ -f "$tgz" ]] && npm install -g "$tgz"
  done
fi

# 6. Cargo
if command -v cargo >/dev/null 2>&1 && [[ -d "$CACHE_DIR/cargo/registry" ]] && [[ -f "$META_DIR/cargo-packages.txt" ]]; then
  log_section "Cargo: installing from cache"
  export CARGO_HOME="$CACHE_DIR/cargo"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    cargo install "$app" --offline 2>/dev/null || log_warn "Cargo install failed: $app"
  done < "$META_DIR/cargo-packages.txt"
  unset CARGO_HOME
fi

# 7. Vendor .dmg/.pkg - manual
if ls "$CACHE_DIR/vendor/"*.dmg "$CACHE_DIR/vendor/"*.pkg 2>/dev/null; then
  log_section "Vendor: manual installers present"
  log_info "Open cache/macos/vendor/ and install .dmg/.pkg manually. See MANUAL-SOFTWARE-NOTES.txt"
fi

log_section "macOS offline installation complete"
log_info "Check cache/macos/vendor/MANUAL-SOFTWARE-NOTES.txt for manual install steps."
