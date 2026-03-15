#!/usr/bin/env bash
# Run on macOS when ONLINE. Fills cache/macos/ from macos-rebuild-framework manifests.
# Usage: ./download-macos.sh --profile <macbook|mac-mini>

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP_CACHE="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$MP_CACHE/cache/macos"

if [[ -n "${FRAMEWORKS_ROOT:-}" ]]; then
  ROOT_DIR="$(cd "$FRAMEWORKS_ROOT/macos-rebuild-framework" && pwd)"
else
  PATHS_ENV="$MP_CACHE/config/paths.env"
  if [[ -f "$PATHS_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$PATHS_ENV"
    [[ -n "${FRAMEWORKS_ROOT:-}" ]] && ROOT_DIR="$(cd "$FRAMEWORKS_ROOT/macos-rebuild-framework" && pwd)"
  fi
fi
[[ -z "${ROOT_DIR:-}" ]] && ROOT_DIR="$(cd "$MP_CACHE/../macos-rebuild-framework" && pwd)"

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: macos-rebuild-framework not found at $ROOT_DIR. Set FRAMEWORKS_ROOT or config/paths.env" >&2
  exit 1
fi

[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
[[ -x /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)"

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/logging.sh"

PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    -h|--help) echo "Usage: $0 --profile <name>"; exit 0 ;;
    *) log_error "Unknown: $1"; exit 1 ;;
  esac
done
[[ -n "$PROFILE" ]] || { log_error "Missing --profile"; exit 1; }

PROFILE_FILE="$ROOT_DIR/profiles/${PROFILE}.env"
[[ -f "$PROFILE_FILE" ]] || die "Profile not found: $PROFILE_FILE"
load_profile "$PROFILE_FILE"

mkdir -p "$CACHE_DIR"/{brew,pip,pipx,uv,npm,cargo,vendor,meta}

TIMESTAMP="$(date +%F-%H%M%S)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
cat > "$CACHE_DIR/meta/collection-info.txt" <<META
profile=$PROFILE
collection_timestamp=$TIMESTAMP
macos_version=$MACOS_VERSION
hostname=$(hostname)
arch=$(uname -m)
source=multi-platform-offline-cache
META

# Copy manifest lists for install-from-cache
for f in brew-packages.txt brew-casks.txt pip-user-packages.txt pipx-packages.txt uv-tools.txt npm-global-packages.txt cargo-packages.txt; do
  [[ -f "$ROOT_DIR/manifests/$f" ]] && cp "$ROOT_DIR/manifests/$f" "$CACHE_DIR/meta/$f"
done

log_info "Creating macOS offline cache for profile: $PROFILE (output: $CACHE_DIR)"

# 1. Homebrew
if command -v brew >/dev/null 2>&1; then
  log_section "Homebrew: fetching formulae and casks"
  brew_pkgs=()
  [[ -f "$ROOT_DIR/manifests/brew-packages.txt" ]] && while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    brew_pkgs+=("$pkg")
  done < "$ROOT_DIR/manifests/brew-packages.txt"
  if ((${#brew_pkgs[@]} > 0)); then
    log_info "Fetching ${#brew_pkgs[@]} formulae"
    run_cmd brew fetch "${brew_pkgs[@]}" --force 2>/dev/null || true
    HOMEBREW_CACHE="${HOMEBREW_CACHE:-$(brew --cache)}"
    [[ -d "$HOMEBREW_CACHE" ]] && run_cmd cp -Rn "$HOMEBREW_CACHE"/* "$CACHE_DIR/brew/" 2>/dev/null || true
  fi
  if want_feature INSTALL_BREW_CASKS && [[ -f "$ROOT_DIR/manifests/brew-casks.txt" ]]; then
    cask_list=()
    while IFS= read -r cask; do
      [[ -z "$cask" || "$cask" =~ ^# ]] && continue
      cask_list+=("$cask")
    done < "$ROOT_DIR/manifests/brew-casks.txt"
    if ((${#cask_list[@]} > 0)); then
      log_info "Fetching ${#cask_list[@]} casks"
      for c in "${cask_list[@]}"; do run_cmd brew fetch --cask "$c" 2>/dev/null || true; done
      HOMEBREW_CACHE="${HOMEBREW_CACHE:-$(brew --cache)}"
      [[ -d "$HOMEBREW_CACHE" ]] && run_cmd cp -Rn "$HOMEBREW_CACHE"/* "$CACHE_DIR/brew/" 2>/dev/null || true
    fi
  fi
  brew list --formula 2>/dev/null | sort > "$CACHE_DIR/brew/formula-list.txt" || true
  brew list --cask 2>/dev/null | sort > "$CACHE_DIR/brew/cask-list.txt" || true
fi

# 2. Pip user
if [[ -f "$ROOT_DIR/manifests/pip-user-packages.txt" ]] && command -v python3 >/dev/null 2>&1; then
  pip_user_list=()
  while IFS= read -r pkg; do [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue; pip_user_list+=("$pkg"); done < "$ROOT_DIR/manifests/pip-user-packages.txt"
  if ((${#pip_user_list[@]} > 0)); then
    log_section "Pip user: downloading packages"
    printf '%s\n' "${pip_user_list[@]}" > "$CACHE_DIR/pip/pip-user-freeze.txt"
    python3 -m pip download -r "$CACHE_DIR/pip/pip-user-freeze.txt" -d "$CACHE_DIR/pip/wheelhouse" || log_warn "Some pip user wheels could not be downloaded"
  fi
fi

# 3. Pipx
if want_feature INSTALL_PIPX && [[ -f "$ROOT_DIR/manifests/pipx-packages.txt" ]]; then
  log_section "Pipx: downloading wheels"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    pip download "$app" -d "$CACHE_DIR/pipx" 2>/dev/null || log_warn "Pip download failed: $app"
  done < "$ROOT_DIR/manifests/pipx-packages.txt"
fi

# 4. UV
if want_feature INSTALL_UV_TOOLS && command -v uv >/dev/null 2>&1 && [[ -f "$ROOT_DIR/manifests/uv-tools.txt" ]]; then
  log_section "UV: downloading tools"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    pip download "$app" -d "$CACHE_DIR/uv" 2>/dev/null || log_warn "UV/pip download failed: $app"
  done < "$ROOT_DIR/manifests/uv-tools.txt"
fi

# 5. NPM
if want_feature INSTALL_NPM_GLOBAL && command -v npm >/dev/null 2>&1 && [[ -f "$ROOT_DIR/manifests/npm-global-packages.txt" ]]; then
  log_section "NPM: packing packages"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    (cd "$CACHE_DIR/npm" && npm pack "$app" 2>/dev/null) || log_warn "NPM pack failed: $app"
  done < "$ROOT_DIR/manifests/npm-global-packages.txt"
fi

# 6. Cargo
if want_feature INSTALL_CARGO && command -v cargo >/dev/null 2>&1 && [[ -f "$ROOT_DIR/manifests/cargo-packages.txt" ]]; then
  log_section "Cargo: fetching crates"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    cargo install "$app" 2>/dev/null || log_warn "Cargo install failed: $app"
  done < "$ROOT_DIR/manifests/cargo-packages.txt"
  [[ -d "$HOME/.cargo/registry" ]] && run_cmd cp -a "$HOME/.cargo/registry" "$CACHE_DIR/cargo/" 2>/dev/null || log_warn "Could not copy cargo registry"
fi

# 7. Vendor URLs
if [[ -f "$ROOT_DIR/manifests/vendor-download-urls.txt" ]]; then
  log_section "Vendor: downloading from URL list"
  while IFS= read -r line; do
    line="${line%%#*}"
    [[ -z "${line// /}" ]] && continue
    read -r url fname _ <<< "$line"
    fname="${fname:-$(basename "$url")}"
    (cd "$CACHE_DIR/vendor" && curl -sSL -o "$fname" "$url") && log_info "Downloaded: $fname" || log_warn "Failed: $url"
  done < "$ROOT_DIR/manifests/vendor-download-urls.txt"
fi
[[ -n "${OFFLINE_VENDOR_SOURCE_DIR:-}" && -d "$OFFLINE_VENDOR_SOURCE_DIR" ]] && run_cmd cp -a "$OFFLINE_VENDOR_SOURCE_DIR"/* "$CACHE_DIR/vendor/" 2>/dev/null || true

cat > "$CACHE_DIR/vendor/README.txt" <<'VENDORREADME'
Place manual installers here (.dmg, .pkg). See MANUAL-SOFTWARE-NOTES.txt for install steps.
VENDORREADME
[[ -f "$CACHE_DIR/vendor/MANUAL-SOFTWARE-NOTES.txt" ]] || echo "# Add notes per installer" > "$CACHE_DIR/vendor/MANUAL-SOFTWARE-NOTES.txt"

log_section "Creating checksum manifest"
(cd "$CACHE_DIR" && find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS) || true

log_section "Download complete"
log_info "Cache size: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
log_info "macOS cache is at: $CACHE_DIR"
