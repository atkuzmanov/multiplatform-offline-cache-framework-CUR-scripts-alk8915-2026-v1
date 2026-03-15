# Multi-Platform Offline Cache

Download and cache installation files for **Ubuntu Linux**, **macOS**, and **Windows** so you can set up a machine without internet (or from external storage: USB, HDD, etc.).

- **Ubuntu** and **macOS** software lists come from the existing `ubuntu-rebuild-framework` and `macos-rebuild-framework` (manifests and state).
- **Windows** uses `windows-rebuild-framework` manifests; for software that exists only on Ubuntu/macOS, the **top two Windows alternatives** are downloaded (see `config/windows-alternatives.yaml`).

Final layout:

```
cache/
├── ubuntu/    # .deb, snap, flatpak, pip wheels, vendor installers, etc.
├── macos/     # Homebrew bottles/casks, .dmg/.pkg, pip/npm/cargo cache
└── windows/   # Winget, Chocolatey, vendor .exe/.msi, pip/npm
```

## Quick start

1. **Configure paths**  
   Copy `config/paths.env.example` to `config/paths.env` and set `FRAMEWORKS_ROOT` to the directory that contains `ubuntu-rebuild-framework`, `macos-rebuild-framework`, and `windows-rebuild-framework`. If this folder lives next to them, the default may already work.

2. **Generate Windows manifest (including alternatives)**  
   Run once (from any OS with Python 3):

   ```bash
   python3 scripts/merge-manifests.py
   ```

   This reads Ubuntu/macOS manifests and `config/windows-alternatives.yaml`, and writes `config/generated/winget-with-alternatives.txt` (and optional choco/vendor lists) for the Windows download step.

3. **Download each platform’s cache** (run on the matching OS):

   - **On Ubuntu:**  
     `./scripts/download-ubuntu.sh`  
     Fills `cache/ubuntu/` from `ubuntu-rebuild-framework` manifests/state.

   - **On macOS:**  
     `./scripts/download-macos.sh`  
     Fills `cache/macos/` from `macos-rebuild-framework` manifests/state.

   - **On Windows (PowerShell):**  
     `.\scripts\download-windows.ps1`  
     Fills `cache/windows/` from `windows-rebuild-framework` manifests and the generated Windows list (including alternatives).

4. **Copy the whole folder** (including `cache/`) to external storage.

5. **On a target machine (offline):**  
   Run the install script for that OS from the copied folder:

   - **Ubuntu:** `./scripts/install-from-cache-ubuntu.sh --profile <profile>`
   - **macOS:** `./scripts/install-from-cache-macos.sh --profile <profile>`
   - **Windows:** `.\scripts\install-from-cache-windows.ps1 -Profile <profile>`

   Use the same profile name you use in the corresponding rebuild framework (e.g. `laptop`, `workstation`, `macbook`, `desktop`).

## Config

- **`config/paths.env`** – `FRAMEWORKS_ROOT` (parent of the three framework dirs). Scripts source this when present.
- **`config/windows-alternatives.yaml`** – Maps “logical” app names (from Ubuntu/macOS) that have no direct Windows version to up to two Windows alternatives (Winget IDs, Chocolatey packages, or vendor URLs). Edit this to add or change alternatives.
- **`config/generated/`** – Output of `merge-manifests.py` (winget/choco/vendor lists including alternatives). Regenerate after changing manifests or `windows-alternatives.yaml`.

## Adding or changing Windows alternatives

Edit `config/windows-alternatives.yaml`. Each entry can list:

- `winget_ids`: list of Winget package IDs (e.g. `Microsoft.WindowsTerminal`).
- `choco_packages`: list of Chocolatey package names.
- `vendor_urls`: list of URLs (optional filename as second column) for direct downloads.

Then run `python3 scripts/merge-manifests.py` and re-run `download-windows.ps1` when online.

## Requirements

- **Merge script:** Python 3.6+, PyYAML (`pip install pyyaml` or use system package).
- **Download/install Ubuntu:** Bash, apt/snap/flatpak/pip/pipx/npm/cargo as in `ubuntu-rebuild-framework`.
- **Download/install macOS:** Bash, Homebrew; optionally pip, npm, cargo as in `macos-rebuild-framework`.
- **Download/install Windows:** PowerShell 5.1+; Winget; optionally Chocolatey, pip, npm as in `windows-rebuild-framework`.

## Directory layout

```
multi-platform-offline-cache/
├── README.md
├── config/
│   ├── paths.env.example
│   ├── paths.env              # you create; gitignore
│   ├── windows-alternatives.yaml
│   └── generated/             # from merge-manifests.py
│       ├── winget-with-alternatives.txt
│       └── ...
├── cache/                     # all downloaded files (gitignore)
│   ├── ubuntu/
│   ├── macos/
│   └── windows/
└── scripts/
    ├── merge-manifests.py
    ├── download-ubuntu.sh
    ├── download-macos.sh
    ├── download-windows.ps1
    ├── install-from-cache-ubuntu.sh
    ├── install-from-cache-macos.sh
    └── install-from-cache-windows.ps1
```

## Notes

- **Vendor URLs:** Each platform’s framework has a vendor/URL list (e.g. `manifests/vendor-download-urls.txt`). The download scripts use those; add platform-specific URLs there for manual installers.
- **Profiles:** Install-from-cache scripts use the same profile names as the rebuild frameworks so feature flags (e.g. which sets of packages to install) stay consistent.
- **Size:** Cache size can be large (tens of GB). Check `cache/` size before copying to removable media.
