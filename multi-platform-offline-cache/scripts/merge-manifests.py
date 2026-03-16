#!/usr/bin/env python3
"""
Merge Ubuntu/macOS manifest entries with Windows alternatives and produce
a combined Windows manifest (winget + choco + vendor URLs) for the offline cache.

Reads:
  - FRAMEWORKS_ROOT/ubuntu-rebuild-framework/manifests/
  - FRAMEWORKS_ROOT/macos-rebuild-framework/manifests/
  - FRAMEWORKS_ROOT/windows-rebuild-framework/manifests/
  - config/windows-alternatives.yaml

Writes:
  - config/generated/winget-with-alternatives.txt
  - config/generated/choco-with-alternatives.txt (optional)
  - config/generated/vendor-download-urls-merged.txt (optional)

Usage: python3 scripts/merge-manifests.py
       FRAMEWORKS_ROOT can be set in config/paths.env or as env var; else assumes parent of multi-platform-offline-cache.
"""

from pathlib import Path
import os
import re
import sys

try:
    import yaml
except ImportError:
    print("PyYAML required: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def find_frameworks_root(script_dir: Path) -> Path:
    """Resolve FRAMEWORKS_ROOT: env > config/paths.env > parent of multi-platform-offline-cache."""
    root_env = os.environ.get("FRAMEWORKS_ROOT")
    if root_env:
        return Path(root_env).resolve()
    # multi-platform-offline-cache/scripts -> multi-platform-offline-cache -> parent
    mp_cache = script_dir.parent
    paths_env = mp_cache / "config" / "paths.env"
    if paths_env.exists():
        for line in paths_env.read_text().splitlines():
            line = line.strip()
            if line.startswith("FRAMEWORKS_ROOT="):
                val = line.split("=", 1)[1].strip().strip('"').strip("'")
                if val:
                    return Path(val).resolve()
    # Default: parent of multi-platform-offline-cache
    return mp_cache.parent.resolve()


def read_lines(path: Path, comment="#", empty_skip=True) -> list[str]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if empty_skip and not line:
            continue
        if comment and line.startswith(comment):
            continue
        out.append(line)
    return out


def read_winget_ids(path: Path) -> set[str]:
    ids = set()
    for line in read_lines(path):
        # winget format: Package.Id or Package.Id --source optional
        part = line.split()[0] if line.split() else line
        if "." in part and not part.startswith("#"):
            ids.add(part)
    return ids


def read_choco_packages(path: Path) -> set[str]:
    return set(read_lines(path))


def read_brew_casks(path: Path) -> set[str]:
    return set(read_lines(path))


def normalize_name(name: str) -> str:
    """Normalize for matching (lowercase, strip @version)."""
    return name.split("@")[0].strip().lower()


def load_alternatives(yaml_path: Path) -> dict:
    if not yaml_path.exists():
        return {}
    with open(yaml_path) as f:
        data = yaml.safe_load(f)
    return data or {}


def main():
    script_dir = Path(__file__).resolve().parent
    mp_cache = script_dir.parent
    root = find_frameworks_root(script_dir)

    ubuntu_manifests = root / "ubuntu-rebuild-framework" / "manifests"
    macos_manifests = root / "macos-rebuild-framework" / "manifests"
    windows_manifests = root / "windows-rebuild-framework" / "manifests"
    config_dir = mp_cache / "config"
    generated_dir = config_dir / "generated"
    generated_dir.mkdir(parents=True, exist_ok=True)

    alternatives_path = config_dir / "windows-alternatives.yaml"
    alternatives = load_alternatives(alternatives_path)

    # Existing Windows manifest IDs (so we don't duplicate)
    winget_existing = set()
    choco_existing = set()
    if (windows_manifests / "winget-packages.txt").exists():
        winget_existing = read_winget_ids(windows_manifests / "winget-packages.txt")
    if (windows_manifests / "choco-packages.txt").exists():
        choco_existing = read_choco_packages(windows_manifests / "choco-packages.txt")

    # Brew casks from macOS (many are Mac-only; we want Windows alternatives)
    brew_casks = set()
    brew_casks_file = macos_manifests / "brew-casks.txt"
    if brew_casks_file.exists():
        brew_casks = read_brew_casks(brew_casks_file)

    # Collect additional winget IDs and choco packages from alternatives
    winget_extra = set()
    choco_extra = set()
    def get_alt(key: str):
        alt = alternatives.get(key)
        if alt and isinstance(alt, dict):
            return alt
        # Fallback: strip trailing digits (e.g. adoptopenjdk9 -> adoptopenjdk)
        base = re.sub(r"[0-9]+$", "", key)
        if base != key:
            return alternatives.get(base) if isinstance(alternatives.get(base), dict) else None
        return None

    for cask in brew_casks:
        key = normalize_name(cask)
        alt = get_alt(key) or get_alt(cask)
        if not alt:
            continue
        for wid in alt.get("winget_ids") or []:
            if wid and wid not in winget_existing:
                winget_extra.add(wid)
        for cp in alt.get("choco_packages") or []:
            if cp and cp not in choco_existing:
                choco_extra.add(cp)

    # Merge: existing Windows manifest + alternatives (deduplicated)
    winget_final = sorted(winget_existing) + sorted(winget_extra)
    choco_final = sorted(choco_existing) + sorted(choco_extra)

    # Write generated manifests
    winget_out = generated_dir / "winget-with-alternatives.txt"
    winget_out.write_text(
        "# Winget package IDs (base manifest + alternatives for macOS/Ubuntu-only apps)\n"
        "# Generated by scripts/merge-manifests.py\n\n"
        + "\n".join(winget_final)
        + "\n"
    )
    print(f"Wrote {winget_out} ({len(winget_final)} winget IDs)")

    choco_out = generated_dir / "choco-with-alternatives.txt"
    choco_out.write_text(
        "# Chocolatey packages (base + alternatives)\n"
        "# Generated by scripts/merge-manifests.py\n\n"
        + "\n".join(choco_final)
        + "\n"
    )
    print(f"Wrote {choco_out} ({len(choco_final)} choco packages)")

    # Copy vendor URLs from Windows manifest if present (no merge from Ubuntu/macOS vendor URLs here to avoid wrong platform)
    vendor_src = windows_manifests / "vendor-download-urls.txt"
    vendor_dst = generated_dir / "vendor-download-urls.txt"
    if vendor_src.exists():
        vendor_dst.write_text(vendor_src.read_text())
        print(f"Wrote {vendor_dst} (from windows-rebuild-framework)")
    else:
        vendor_dst.write_text(
            "# Direct download URLs for Windows installers (one per line; optional second column = filename)\n"
        )
        print(f"Wrote {vendor_dst} (empty)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
