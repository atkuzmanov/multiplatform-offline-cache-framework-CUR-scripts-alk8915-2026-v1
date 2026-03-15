# Run on Windows when ONLINE. Fills cache/windows/ from windows-rebuild-framework + generated manifests (with alternatives).
# Usage: .\download-windows.ps1 -Profile <laptop|desktop>
# Prerequisite: run python3 scripts/merge-manifests.py once to generate config/generated/winget-with-alternatives.txt

param([Parameter(Mandatory=$true)][string]$Profile)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$MP_CACHE = (Resolve-Path (Join-Path $ScriptDir '..')).Path
$CACHE_DIR = Join-Path $MP_CACHE 'cache\windows'

# Resolve FRAMEWORKS_ROOT
if ($env:FRAMEWORKS_ROOT) {
    $ROOT_DIR = Join-Path $env:FRAMEWORKS_ROOT 'windows-rebuild-framework'
} else {
    $pathsEnv = Join-Path $MP_CACHE 'config\paths.env'
    if (Test-Path $pathsEnv) {
        Get-Content $pathsEnv | ForEach-Object {
            if ($_ -match '^\s*FRAMEWORKS_ROOT\s*=\s*["'']?(.+?)["'']?\s*$') {
                $env:FRAMEWORKS_ROOT = $matches[1].Trim()
            }
        }
        if ($env:FRAMEWORKS_ROOT) {
            $ROOT_DIR = Join-Path $env:FRAMEWORKS_ROOT 'windows-rebuild-framework'
        }
    }
}
if (-not $ROOT_DIR -or -not (Test-Path $ROOT_DIR)) {
    $ROOT_DIR = Join-Path (Split-Path $MP_CACHE -Parent) 'windows-rebuild-framework'
}
if (-not (Test-Path $ROOT_DIR)) {
    Write-Error "windows-rebuild-framework not found at $ROOT_DIR. Set FRAMEWORKS_ROOT or config/paths.env"
    exit 1
}

$env:ROOT_DIR = $ROOT_DIR
. (Join-Path $ROOT_DIR 'lib\common.ps1')
. (Join-Path $ROOT_DIR 'lib\logging.ps1')

$PROFILE_FILE = Join-Path $ROOT_DIR "profiles\$Profile.env"
if (-not (Test-Path $PROFILE_FILE)) { Die "Profile not found: $PROFILE_FILE" }
Load-Profile $PROFILE_FILE

# Prefer generated manifests (include alternatives); fallback to framework manifests
$generatedDir = Join-Path $MP_CACHE 'config\generated'
$wingetManifest = if (Test-Path (Join-Path $generatedDir 'winget-with-alternatives.txt')) {
    Join-Path $generatedDir 'winget-with-alternatives.txt'
} else {
    Join-Path $ROOT_DIR 'manifests\winget-packages.txt'
}
$chocoManifest = if (Test-Path (Join-Path $generatedDir 'choco-with-alternatives.txt')) {
    Join-Path $generatedDir 'choco-with-alternatives.txt'
} else {
    Join-Path $ROOT_DIR 'manifests\choco-packages.txt'
}
$vendorUrls = if (Test-Path (Join-Path $generatedDir 'vendor-download-urls.txt')) {
    Join-Path $generatedDir 'vendor-download-urls.txt'
} else {
    Join-Path $ROOT_DIR 'manifests\vendor-download-urls.txt'
}

Write-LogInfo "Creating Windows offline cache for profile: $Profile (output: $CACHE_DIR)"
Write-LogInfo "Winget manifest: $wingetManifest"

@('winget', 'choco', 'pip', 'pipx', 'uv', 'npm', 'vendor', 'meta') | ForEach-Object {
    $d = Join-Path $CACHE_DIR $_
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$ts = Get-Date -Format 'yyyy-MM-dd-HHmmss'
@"
profile=$Profile
collection_timestamp=$ts
hostname=$env:COMPUTERNAME
windows_version=$([System.Environment]::OSVersion.Version.ToString())
source=multi-platform-offline-cache
"@ | Out-File (Join-Path $CACHE_DIR 'meta\collection-info.txt') -Encoding utf8

# Copy manifest lists for install-from-cache
foreach ($f in @('winget-with-alternatives.txt', 'choco-with-alternatives.txt')) {
    $src = Join-Path $generatedDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $CACHE_DIR "meta\$f") -Force }
}
$wingetManifestSrc = Join-Path $ROOT_DIR 'manifests\winget-packages.txt'
if (Test-Path $wingetManifestSrc) { Copy-Item $wingetManifestSrc (Join-Path $CACHE_DIR 'meta\winget-packages.txt') -Force }
$chocoManifestSrc = Join-Path $ROOT_DIR 'manifests\choco-packages.txt'
if (Test-Path $chocoManifestSrc) { Copy-Item $chocoManifestSrc (Join-Path $CACHE_DIR 'meta\choco-packages.txt') -Force }

# 1. Winget
Write-LogSection 'Winget: downloading'
$wingetOut = Join-Path $CACHE_DIR 'winget'
if ((Test-WantFeature 'INSTALL_WINGET_PACKAGES') -and (Test-Path $wingetManifest)) {
    Get-Content $wingetManifest | ForEach-Object {
        $id = $_.Trim()
        if (-not $id -or $id.StartsWith('#')) { return }
        Write-LogInfo "Downloading winget: $id"
        try {
            winget download --id $id --accept-package-agreements --accept-source-agreements --download-directory $wingetOut 2>$null
        } catch { Write-LogWarn "Winget download failed: $id" }
    }
    try {
        winget export -o (Join-Path $wingetOut 'winget-export.json') 2>$null
    } catch { }
}

# 2. Chocolatey
if ((Test-WantFeature 'INSTALL_CHOCO_PACKAGES') -and (Get-Command choco -ErrorAction SilentlyContinue) -and (Test-Path $chocoManifest)) {
    Write-LogSection 'Chocolatey: downloading packages'
    $chocoOut = Join-Path $CACHE_DIR 'choco'
    Get-Content $chocoManifest | ForEach-Object {
        $pkg = $_.Trim()
        if (-not $pkg -or $pkg.StartsWith('#')) { return }
        Write-LogInfo "Downloading choco: $pkg"
        try {
            choco download $pkg --no-progress -y -o $chocoOut 2>$null
        } catch { Write-LogWarn "Choco download failed: $pkg" }
    }
}

# 3. Pipx
if ((Test-WantFeature 'INSTALL_PIPX') -and (Get-Command pip -ErrorAction SilentlyContinue)) {
    Write-LogSection 'Pipx: downloading wheels'
    $pipxManifest = Join-Path $ROOT_DIR 'manifests\pipx-packages.txt'
    $pipxOut = Join-Path $CACHE_DIR 'pipx'
    if (Test-Path $pipxManifest) {
        Get-Content $pipxManifest | ForEach-Object {
            $app = $_.Trim()
            if (-not $app -or $app.StartsWith('#')) { return }
            try { pip download $app -d $pipxOut 2>$null } catch { Write-LogWarn "Pip download failed: $app" }
        }
    }
}

# 4. NPM
if ((Test-WantFeature 'INSTALL_NPM_GLOBAL') -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-LogSection 'NPM: packing packages'
    $npmManifest = Join-Path $ROOT_DIR 'manifests\npm-global-packages.txt'
    $npmOut = Join-Path $CACHE_DIR 'npm'
    if (Test-Path $npmManifest) {
        Get-Content $npmManifest | ForEach-Object {
            $pkg = $_.Trim()
            if (-not $pkg -or $pkg.StartsWith('#')) { return }
            try {
                Push-Location $npmOut; npm pack $pkg 2>$null; Pop-Location
            } catch { Write-LogWarn "NPM pack failed: $pkg" }
        }
    }
}

# 5. Vendor URLs
$vendorDir = Join-Path $CACHE_DIR 'vendor'
if (Test-Path $vendorUrls) {
    Write-LogSection 'Vendor: downloading from URL list'
    Get-Content $vendorUrls | ForEach-Object {
        $line = $_.Trim() -replace '#.*',''
        if (-not $line) { return }
        $parts = $line -split '\s+', 2
        $url = $parts[0]
        $fname = if ($parts.Length -gt 1) { $parts[1] } else { [System.IO.Path]::GetFileName($url) }
        try {
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $vendorDir $fname) -UseBasicParsing
            Write-LogInfo "Downloaded: $fname"
        } catch { Write-LogWarn "Failed: $url" }
    }
}

# Checksums
Write-LogSection 'Creating checksum manifest'
$sumFile = Join-Path $CACHE_DIR 'SHA256SUMS.txt'
Get-ChildItem $CACHE_DIR -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    "$hash  $($_.FullName.Replace($CACHE_DIR, '.').Replace('\', '/'))"
} | Out-File $sumFile -Encoding utf8

Write-LogSection 'Download complete'
$size = (Get-ChildItem $CACHE_DIR -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB
Write-LogInfo "Cache size: $([math]::Round($size, 2)) GB"
Write-LogInfo "Windows cache is at: $CACHE_DIR"
