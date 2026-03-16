# Run OFFLINE on Windows. Installs from cache/windows/ (no network required).
# Usage: .\install-from-cache-windows.ps1 [-Profile <name>]
# Run from the multi-platform-offline-cache folder (e.g. from USB). Profile is optional.

param([string]$Profile = 'desktop')

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$MP_ROOT = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$CACHE_DIR = Join-Path $MP_ROOT 'cache\windows'
$META_DIR = Join-Path $CACHE_DIR 'meta'

if (-not (Test-Path $CACHE_DIR)) {
    Write-Error "cache\windows not found at $CACHE_DIR. Copy the full multi-platform-offline-cache folder (including cache\) to this machine."
    exit 1
}

function Write-LogInfo { param($m) Write-Host "[INFO] $m" }
function Write-LogWarn { param($m) Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Write-LogSection { param($m) Write-Host "`n===== $m =====" }

# Optional checksum verify
$sumFile = Join-Path $CACHE_DIR 'SHA256SUMS.txt'
if (Test-Path $sumFile) {
    Write-LogSection 'Verifying checksums (optional)'
    Get-Content $sumFile | ForEach-Object {
        $parts = $_ -split '\s+', 2
        if ($parts.Length -eq 2) {
            $path = Join-Path $CACHE_DIR ($parts[1].TrimStart('.\').Replace('/', '\'))
            if (Test-Path $path) {
                $current = (Get-FileHash $path -Algorithm SHA256).Hash
                if ($current -ne $parts[0]) { Write-LogWarn "Mismatch: $path" }
            }
        }
    }
}

Write-LogSection 'Installing from Windows offline cache'

# 1. Winget: import or install from downloaded files
$wingetDir = Join-Path $CACHE_DIR 'winget'
$wingetExport = Join-Path $wingetDir 'winget-export.json'
if (Test-Path $wingetExport) {
    Write-LogSection 'Winget: importing from export'
    try {
        winget import -i $wingetExport --accept-package-agreements --accept-source-agreements
    } catch { Write-LogWarn "Winget import failed: $_" }
}
Get-ChildItem $wingetDir -Filter '*.msix' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-LogInfo "Installing: $($_.Name)"
    try {
        winget install --id $_.BaseName --silent --accept-package-agreements 2>$null
    } catch { Write-LogWarn "Winget install failed: $($_.Name)" }
}

# 2. Chocolatey: install from nupkg
if (Get-Command choco -ErrorAction SilentlyContinue) {
    $chocoDir = Join-Path $CACHE_DIR 'choco'
    if (Test-Path $chocoDir) {
        Write-LogSection 'Chocolatey: installing from cache'
        Get-ChildItem $chocoDir -Filter '*.nupkg' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Write-LogInfo "Installing: $($_.Name)"
            try { choco install $_.FullName -y --no-progress 2>$null } catch { Write-LogWarn "Choco install failed: $($_.Name)" }
        }
    }
}

# 3. Pipx: install from wheels in cache
if (Get-Command pipx -ErrorAction SilentlyContinue) {
    $pipxDir = Join-Path $CACHE_DIR 'pipx'
    if (Test-Path $pipxDir) {
        Write-LogSection 'Pipx: installing from cache'
        Get-ChildItem $pipxDir -Filter '*.whl' -ErrorAction SilentlyContinue | ForEach-Object {
            Write-LogInfo "Installing pipx: $($_.Name)"
            try { pipx install $_.FullName } catch { Write-LogWarn "Pipx install failed: $($_.Name)" }
        }
    }
}

# 4. NPM: install from tgz
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $npmDir = Join-Path $CACHE_DIR 'npm'
    if (Test-Path $npmDir) {
        Write-LogSection 'NPM: installing from cache'
        Get-ChildItem $npmDir -Filter '*.tgz' -ErrorAction SilentlyContinue | ForEach-Object {
            npm install -g $_.FullName
        }
    }
}

# 5. Vendor: run installers (user must run .exe/.msi manually or we could invoke)
$vendorDir = Join-Path $CACHE_DIR 'vendor'
if (Test-Path $vendorDir) {
    $exes = Get-ChildItem $vendorDir -Filter '*.exe' -ErrorAction SilentlyContinue
    $msis = Get-ChildItem $vendorDir -Filter '*.msi' -ErrorAction SilentlyContinue
    if ($exes -or $msis) {
        Write-LogSection 'Vendor: installers present'
        Write-LogInfo "Run .exe/.msi from cache\windows\vendor\ manually, or use: Start-Process <path> -Wait"
    }
}

Write-LogSection 'Windows offline installation complete'
Write-LogInfo 'Check cache\windows\vendor for any manual installers.'
