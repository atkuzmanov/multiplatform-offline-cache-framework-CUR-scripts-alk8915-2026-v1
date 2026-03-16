#!/usr/bin/env bash
# Run OFFLINE on Ubuntu. Installs from cache/ubuntu/ (no network required).
# Usage: ./install-from-cache-ubuntu.sh [--profile <name>]
# Run from the multi-platform-offline-cache folder (e.g. from USB). Profile is optional (for logging).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$MP_ROOT/cache/ubuntu"
META_DIR="$CACHE_DIR/meta"

if [[ ! -d "$CACHE_DIR" ]]; then
  echo "Error: cache/ubuntu not found at $CACHE_DIR. Copy the full multi-platform-offline-cache folder (including cache/) to this machine." >&2
  exit 1
fi

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_section() { echo ""; echo "===== $* ====="; }

# Optional checksum verify
if [[ -f "$CACHE_DIR/SHA256SUMS" ]]; then
  log_section "Verifying checksums (optional)"
  (cd "$CACHE_DIR" && sha256sum -c SHA256SUMS 2>/dev/null) || log_warn "Some checksums failed; continuing."
fi

log_section "Installing from Ubuntu offline cache"

# 1. APT: add local repo and install
if [[ -f "$CACHE_DIR/apt/Packages.gz" ]] && ls "$CACHE_DIR/apt/"*.deb >/dev/null 2>&1; then
  log_section "APT: installing from local cache"
  if [[ -d "$CACHE_DIR/apt-keys" ]] && ls "$CACHE_DIR/apt-keys/"* >/dev/null 2>&1; then
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo cp -n "$CACHE_DIR/apt-keys/"* /etc/apt/keyrings/ 2>/dev/null || true
  fi
  echo "deb [trusted=yes] file://$CACHE_DIR/apt ./" | sudo tee /etc/apt/sources.list.d/offline-cache.list
  sudo apt-get update 2>/dev/null || true

  apt_pkgs=()
  manifest="$META_DIR/apt-packages.txt"
  [[ -f "$manifest" ]] && while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    apt_pkgs+=("$pkg")
  done < "$manifest"

  if ((${#apt_pkgs[@]} > 0)); then
    sudo apt-get install -y --allow-unauthenticated "${apt_pkgs[@]}" 2>/dev/null || {
      log_warn "APT install had issues; attempting dpkg + fix"
      sudo dpkg -i "$CACHE_DIR/apt/"*.deb 2>/dev/null || true
      sudo apt-get install -f -y 2>/dev/null || true
    }
  else
    sudo dpkg -i "$CACHE_DIR/apt/"*.deb 2>/dev/null || true
    sudo apt-get install -f -y 2>/dev/null || true
  fi
  sudo apt-get install -f -y 2>/dev/null || true
else
  log_warn "No apt cache found; skipping"
fi

# 2. Snap
if command -v snap >/dev/null 2>&1 && ls "$CACHE_DIR/snap/"*.snap >/dev/null 2>&1; then
  log_section "Snap: installing from cache"
  declare -A snap_args
  manifest="$META_DIR/snap-packages.txt"
  [[ -f "$manifest" ]] && while IFS='|' read -r pkg args _; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    snap_args["$pkg"]="$args"
  done < "$manifest"
  for snapfile in "$CACHE_DIR/snap/"*.snap; do
    [[ -f "$snapfile" ]] || continue
    base="$(basename "$snapfile" .snap)"
    pkg="${base%%_*}"
    if snap list "$pkg" >/dev/null 2>&1; then
      log_info "Snap already installed: $pkg"
    else
      assertfile="${snapfile%.snap}.assert"
      [[ -f "$assertfile" ]] && sudo snap ack "$assertfile"
      extra="${snap_args[$pkg]:-}"
      sudo snap install "$snapfile" "$extra" 2>/dev/null || sudo snap install "$snapfile" --dangerous "$extra"
    fi
  done
fi

# 3. Flatpak
if command -v flatpak >/dev/null 2>&1 && ls "$CACHE_DIR/flatpak/"*.flatpak >/dev/null 2>&1; then
  log_section "Flatpak: installing from bundles"
  for bundle in "$CACHE_DIR/flatpak/"*.flatpak; do
    [[ -f "$bundle" ]] && flatpak install -y --or-update "$bundle"
  done
fi

# 4. Pip user
if [[ -d "$CACHE_DIR/pip/wheelhouse" && -f "$CACHE_DIR/pip/pip-user-freeze.txt" ]] && command -v python3 >/dev/null 2>&1; then
  log_section "Pip user: installing from cache"
  python3 -m pip install --user --no-index --find-links "$CACHE_DIR/pip/wheelhouse" -r "$CACHE_DIR/pip/pip-user-freeze.txt" || log_warn "Some pip user packages failed"
fi

# 5. Pipx
if command -v pipx >/dev/null 2>&1 && [[ -f "$META_DIR/pipx-packages.txt" ]]; then
  log_section "Pipx: installing from cache"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    whl="$(ls "$CACHE_DIR/pipx/"*"${app}"*.whl "$CACHE_DIR/pipx/${app}"*.whl 2>/dev/null | head -1)"
    [[ -n "$whl" && -f "$whl" ]] && pipx install "$whl" || log_warn "No wheel for: $app"
  done < "$META_DIR/pipx-packages.txt"
fi

# 6. UV
if command -v uv >/dev/null 2>&1 && [[ -f "$META_DIR/uv-tools.txt" ]]; then
  log_section "UV: installing from cache"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    whl="$(ls "$CACHE_DIR/uv/"*"${app}"*.whl "$CACHE_DIR/uv/${app}"*.whl 2>/dev/null | head -1)"
    [[ -n "$whl" && -f "$whl" ]] && uv tool install "$whl" || log_warn "No wheel for uv: $app"
  done < "$META_DIR/uv-tools.txt"
fi

# 7. NPM
if command -v npm >/dev/null 2>&1 && ls "$CACHE_DIR/npm/"*.tgz >/dev/null 2>&1; then
  log_section "NPM: installing from cache"
  for tgz in "$CACHE_DIR/npm/"*.tgz; do
    [[ -f "$tgz" ]] && sudo npm install -g "$tgz"
  done
fi

# 8. Cargo (offline if registry was cached)
if command -v cargo >/dev/null 2>&1 && [[ -d "$CACHE_DIR/cargo/registry" ]] && [[ -f "$META_DIR/cargo-packages.txt" ]]; then
  log_section "Cargo: installing from cache"
  export CARGO_HOME="$CACHE_DIR/cargo"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    cargo install "$app" --offline 2>/dev/null || log_warn "Cargo install failed: $app"
  done < "$META_DIR/cargo-packages.txt"
  unset CARGO_HOME
fi

# 9. Vendor .deb and AppImages
if ls "$CACHE_DIR/vendor/"*.deb >/dev/null 2>&1; then
  log_section "Vendor: installing .deb from cache"
  for deb in "$CACHE_DIR/vendor/"*.deb; do [[ -f "$deb" ]] && sudo dpkg -i "$deb" 2>/dev/null || true; done
  sudo apt-get install -f -y 2>/dev/null || true
fi
for appimg in "$CACHE_DIR/vendor/"*.AppImage; do
  [[ -f "$appimg" ]] && chmod +x "$appimg" && mkdir -p "$HOME/Applications" && cp "$appimg" "$HOME/Applications/"
done

log_section "Ubuntu offline installation complete"
log_info "Check cache/ubuntu/vendor/MANUAL-SOFTWARE-NOTES.txt for any manual install steps."
