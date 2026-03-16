#!/usr/bin/env bash
# Run on Ubuntu when ONLINE. Fills cache/ubuntu/ from ubuntu-rebuild-framework manifests.
# Usage: ./download-ubuntu.sh --profile <laptop|workstation|vm>

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP_CACHE="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$MP_CACHE/cache/ubuntu"

# Resolve FRAMEWORKS_ROOT
if [[ -n "${FRAMEWORKS_ROOT:-}" ]]; then
  ROOT_DIR="$(cd "$FRAMEWORKS_ROOT/ubuntu-rebuild-framework" && pwd)"
else
  PATHS_ENV="$MP_CACHE/config/paths.env"
  if [[ -f "$PATHS_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$PATHS_ENV"
    if [[ -n "${FRAMEWORKS_ROOT:-}" ]]; then
      ROOT_DIR="$(cd "$FRAMEWORKS_ROOT/ubuntu-rebuild-framework" && pwd)"
    fi
  fi
fi
if [[ -z "${ROOT_DIR:-}" ]]; then
  # Default: parent of multi-platform-offline-cache contains ubuntu-rebuild-framework
  ROOT_DIR="$(cd "$MP_CACHE/../ubuntu-rebuild-framework" && pwd)"
fi

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: ubuntu-rebuild-framework not found at $ROOT_DIR. Set FRAMEWORKS_ROOT or config/paths.env" >&2
  exit 1
fi

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

mkdir -p "$CACHE_DIR"/{apt,apt-keys,snap,flatpak,pip,pipx,uv,npm,cargo,vendor,meta}

UBUNTU_CODENAME="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-unknown}")"
TIMESTAMP="$(date +%F-%H%M%S)"
cat > "$CACHE_DIR/meta/collection-info.txt" <<META
profile=$PROFILE
collection_timestamp=$TIMESTAMP
ubuntu_codename=$UBUNTU_CODENAME
hostname=$(hostname)
kernel=$(uname -r)
source=multi-platform-offline-cache
META

# Write manifest lists for install-from-cache (so we don't depend on framework manifests on target)
cp "$ROOT_DIR/manifests/apt-packages.txt" "$CACHE_DIR/meta/apt-packages.txt" 2>/dev/null || true
[[ -f "$ROOT_DIR/manifests/snap-packages.txt" ]] && cp "$ROOT_DIR/manifests/snap-packages.txt" "$CACHE_DIR/meta/snap-packages.txt"
[[ -f "$ROOT_DIR/manifests/flatpak-packages.txt" ]] && cp "$ROOT_DIR/manifests/flatpak-packages.txt" "$CACHE_DIR/meta/flatpak-packages.txt"
[[ -f "$ROOT_DIR/manifests/pip-user-packages.txt" ]] && cp "$ROOT_DIR/manifests/pip-user-packages.txt" "$CACHE_DIR/meta/pip-user-packages.txt"
[[ -f "$ROOT_DIR/manifests/pipx-packages.txt" ]] && cp "$ROOT_DIR/manifests/pipx-packages.txt" "$CACHE_DIR/meta/pipx-packages.txt"
[[ -f "$ROOT_DIR/manifests/uv-tools.txt" ]] && cp "$ROOT_DIR/manifests/uv-tools.txt" "$CACHE_DIR/meta/uv-tools.txt"
[[ -f "$ROOT_DIR/manifests/npm-global-packages.txt" ]] && cp "$ROOT_DIR/manifests/npm-global-packages.txt" "$CACHE_DIR/meta/npm-global-packages.txt"
[[ -f "$ROOT_DIR/manifests/cargo-packages.txt" ]] && cp "$ROOT_DIR/manifests/cargo-packages.txt" "$CACHE_DIR/meta/cargo-packages.txt"

log_info "Creating Ubuntu offline cache for profile: $PROFILE (output: $CACHE_DIR)"

# 1. APT
log_section "APT: configuring repos and downloading packages"
source "$ROOT_DIR/manifests/apt-repositories.sh" 2>/dev/null || true
configure_docker_repo 2>/dev/null || true
configure_helm_repo 2>/dev/null || true
configure_brave_repo 2>/dev/null || true
run_cmd sudo apt-get update

if [[ -d /etc/apt/keyrings ]]; then
  run_cmd sudo cp -n /etc/apt/keyrings/* "$CACHE_DIR/apt-keys/" 2>/dev/null || true
fi

apt_pkgs=()
while IFS= read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  case "$pkg" in
    cups|system-config-printer|printer-driver-brlaser) want_feature ENABLE_PRINTER_SUPPORT || continue ;;
    simple-scan) want_feature ENABLE_SCANNER_SUPPORT || continue ;;
    timeshift|duplicity|borgbackup|restic|rclone) want_feature ENABLE_BACKUP_TOOLS || continue ;;
    vlc|gimp|imagemagick) want_feature ENABLE_MEDIA_TOOLS || continue ;;
    podman) want_feature ENABLE_VIRTUALIZATION_TOOLS || want_feature ENABLE_DOCKER || continue ;;
  esac
  apt_pkgs+=("$pkg")
done < "$ROOT_DIR/manifests/apt-packages.txt"

want_feature ENABLE_DOCKER && apt_pkgs+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
if want_feature INSTALL_KALI_SAFE_TOOLS && [[ -f "$ROOT_DIR/manifests/kali-safe-apt-packages.txt" ]]; then
  while IFS= read -r pkg; do [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue; apt_pkgs+=("$pkg"); done < "$ROOT_DIR/manifests/kali-safe-apt-packages.txt"
fi

log_info "Downloading ${#apt_pkgs[@]} apt packages and dependencies"
run_cmd sudo apt-get install -y --download-only "${apt_pkgs[@]}"
run_cmd sudo bash -c "cp -n /var/cache/apt/archives/*.deb '$CACHE_DIR/apt/' 2>/dev/null || true"

require_command dpkg-scanpackages || run_cmd sudo apt-get install -y dpkg-dev
(cd "$CACHE_DIR/apt" && dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9c > Packages.gz) || true

# 2. Snap
if want_feature INSTALL_SNAPS; then
  log_section "Snap: downloading packages"
  while IFS='|' read -r pkg args flag; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    [[ -n "$flag" ]] && ! want_feature "$flag" && continue
    log_info "Downloading snap: $pkg"
    (cd "$CACHE_DIR/snap" && snap download "$pkg" "$args" 2>/dev/null) || log_warn "Snap download failed: $pkg"
  done < "$ROOT_DIR/manifests/snap-packages.txt"
fi

# 3. Flatpak
if want_feature INSTALL_FLATPAKS && command -v flatpak >/dev/null 2>&1; then
  log_section "Flatpak: installing and creating bundles"
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
  while IFS='|' read -r pkg flag; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    [[ -n "$flag" ]] && ! want_feature "$flag" && continue
    log_info "Installing and bundling flatpak: $pkg"
    flatpak install -y flathub "$pkg" 2>/dev/null || log_warn "Flatpak install failed: $pkg"
    ref="$(flatpak info --show-ref "$pkg" 2>/dev/null)"
    if [[ -n "$ref" ]]; then
      installation=""
      flatpak info "$pkg" 2>/dev/null | grep -q '^Installation: user' && installation="user"
      if [[ "$installation" == "user" ]] && [[ -d "$HOME/.local/share/flatpak/repo" ]]; then
        run_cmd flatpak build-bundle "$HOME/.local/share/flatpak/repo" "$CACHE_DIR/flatpak/${pkg//[^a-zA-Z0-9._-]/_}.flatpak" "$ref" 2>/dev/null || log_warn "Flatpak bundle failed: $pkg"
      else
        run_cmd flatpak build-bundle /var/lib/flatpak/repo "$CACHE_DIR/flatpak/${pkg//[^a-zA-Z0-9._-]/_}.flatpak" "$ref" 2>/dev/null || log_warn "Flatpak bundle failed: $pkg"
      fi
    fi
  done < "$ROOT_DIR/manifests/flatpak-packages.txt"
fi

# 4. Pip user
if [[ -f "$ROOT_DIR/manifests/pip-user-packages.txt" ]] && command -v python3 >/dev/null 2>&1; then
  pip_user_list=()
  while IFS= read -r pkg; do [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue; pip_user_list+=("$pkg"); done < "$ROOT_DIR/manifests/pip-user-packages.txt"
  if ((${#pip_user_list[@]} > 0)); then
    log_section "Pip user: downloading packages"
    printf '%s\n' "${pip_user_list[@]}" > "$CACHE_DIR/pip/pip-user-freeze.txt"
    python3 -m pip download -r "$CACHE_DIR/pip/pip-user-freeze.txt" -d "$CACHE_DIR/pip/wheelhouse" || log_warn "Some pip user wheels could not be downloaded"
  fi
fi

# 5. Pipx
if want_feature INSTALL_PIPX && command -v pip >/dev/null 2>&1; then
  log_section "Pipx: downloading wheels"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    pip download "$app" -d "$CACHE_DIR/pipx" 2>/dev/null || log_warn "Pip download failed: $app"
  done < "$ROOT_DIR/manifests/pipx-packages.txt"
fi

# 6. UV
if want_feature INSTALL_UV_TOOLS && command -v uv >/dev/null 2>&1; then
  log_section "UV: downloading tools"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    pip download "$app" -d "$CACHE_DIR/uv" 2>/dev/null || log_warn "UV/pip download failed: $app"
  done < "$ROOT_DIR/manifests/uv-tools.txt"
fi

# 7. NPM
if want_feature INSTALL_NPM_GLOBAL && command -v npm >/dev/null 2>&1; then
  log_section "NPM: packing packages"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    (cd "$CACHE_DIR/npm" && npm pack "$app" 2>/dev/null) || log_warn "NPM pack failed: $app"
  done < "$ROOT_DIR/manifests/npm-global-packages.txt"
fi

# 8. Cargo
if want_feature INSTALL_CARGO && command -v cargo >/dev/null 2>&1; then
  log_section "Cargo: fetching crates"
  while IFS= read -r app; do
    [[ -z "$app" || "$app" =~ ^# ]] && continue
    cargo install "$app" 2>/dev/null || log_warn "Cargo install failed: $app"
  done < "$ROOT_DIR/manifests/cargo-packages.txt"
  [[ -d "$HOME/.cargo/registry" ]] && run_cmd cp -a "$HOME/.cargo/registry" "$CACHE_DIR/cargo/" 2>/dev/null || log_warn "Could not copy cargo registry"
fi

# 9. Vendor URLs (Ubuntu-specific)
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

# Optional: copy from OFFLINE_VENDOR_SOURCE_DIR if set
[[ -n "${OFFLINE_VENDOR_SOURCE_DIR:-}" && -d "$OFFLINE_VENDOR_SOURCE_DIR" ]] && run_cmd cp -a "$OFFLINE_VENDOR_SOURCE_DIR"/* "$CACHE_DIR/vendor/" 2>/dev/null || true

cat > "$CACHE_DIR/vendor/README.txt" <<'VENDORREADME'
Place manual installers here (.deb, AppImage, etc.). See MANUAL-SOFTWARE-NOTES.txt for install steps.
VENDORREADME
[[ -f "$CACHE_DIR/vendor/MANUAL-SOFTWARE-NOTES.txt" ]] || echo "# Add notes per installer" > "$CACHE_DIR/vendor/MANUAL-SOFTWARE-NOTES.txt"

log_section "Creating checksum manifest"
(cd "$CACHE_DIR" && find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS) || true

log_section "Download complete"
log_info "Cache size: $(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)"
log_info "Ubuntu cache is at: $CACHE_DIR"
