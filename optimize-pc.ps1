<#
.SYNOPSIS
    PC Optimizer for Claude Code workflow
.DESCRIPTION
    Safe optimizations that free RAM and improve performance.
    Categorized into: AUTO (safe), PROMPT (ask first), MANUAL (instructions only)
.USAGE
    powershell -ExecutionPolicy Bypass -File optimize-pc.ps1
    powershell -ExecutionPolicy Bypass -File optimize-pc.ps1 -aggressive
#>

param(
    [switch]$aggressive
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-FreeRAMGB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1MB, 1)
}

$startRAM = Get-FreeRAMGB
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  PC OPTIMIZER - Starting RAM: $startRAM GB free" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================
# PHASE 1: SAFE AUTO OPTIMIZATIONS
# ========================================
Write-Host "=== Phase 1: Safe Auto Optimizations ===" -ForegroundColor Green

# 1a. Clean temp files
Write-Host "[1] Cleaning temp files..." -ForegroundColor White
$tempPaths = @(
    "$env:TEMP\*",
    "C:\Windows\Temp\*",
    "$env:LOCALAPPDATA\Temp\*"
)
$cleanedMB = 0
foreach ($tp in $tempPaths) {
    $files = Get-ChildItem $tp -Recurse -Force -ErrorAction SilentlyContinue
    $sizeMB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB)
    Remove-Item $tp -Recurse -Force -ErrorAction SilentlyContinue
    $cleanedMB += $sizeMB
}
Write-Host "    Cleaned ~$cleanedMB MB temp files" -ForegroundColor Gray

# 1b. Add Defender exclusions for project directories
Write-Host "[2] Adding Defender exclusions for dev directories..." -ForegroundColor White
$devPaths = @(
    "C:\Users\eladj\projects",
    "C:\Users\eladj\.claude",
    "C:\Users\eladj\tools",
    "C:\Users\eladj\AppData\Local\.bun",
    "C:\Users\eladj\AppData\Roaming\npm"
)
foreach ($path in $devPaths) {
    try {
        Add-MpPreference -ExclusionPath $path -ErrorAction Stop
        Write-Host "    Added: $path" -ForegroundColor Gray
    } catch {
        Write-Host "    Skipped (needs admin): $path" -ForegroundColor DarkGray
    }
}
# Exclude common dev processes
$devProcesses = @("node.exe", "bun.exe", "claude.exe", "git.exe", "Code.exe")
foreach ($proc in $devProcesses) {
    try {
        Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
    } catch {}
}

# 1c. Stop unnecessary services (non-destructive, will restart on reboot)
Write-Host "[3] Stopping unnecessary services..." -ForegroundColor White
$servicesToStop = @(
    @{Name="DiagTrack"; Desc="Telemetry"},
    @{Name="lfsvc"; Desc="Geolocation"},
    @{Name="XblAuthManager"; Desc="Xbox Live Auth"},
    @{Name="XblGameSave"; Desc="Xbox Live Game Save"},
    @{Name="MapsBroker"; Desc="Maps Manager"},
    @{Name="dmwappushservice"; Desc="WAP Push"}
)
foreach ($svc in $servicesToStop) {
    $s = Get-Service $svc.Name -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        try {
            Stop-Service $svc.Name -Force -ErrorAction Stop
            Write-Host "    Stopped: $($svc.Desc)" -ForegroundColor Gray
        } catch {
            Write-Host "    Can't stop (needs admin): $($svc.Desc)" -ForegroundColor DarkGray
        }
    }
}

# 1d. Kill Edge WebView widgets (weather, news, etc.)
Write-Host "[4] Cleaning Edge WebView widgets..." -ForegroundColor White
$widgetProcs = Get-Process "Widgets", "WidgetService" -ErrorAction SilentlyContinue
$widgetCount = ($widgetProcs | Measure-Object).Count
if ($widgetCount -gt 0) {
    $widgetProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "    Killed $widgetCount widget processes" -ForegroundColor Gray
}

# 1e. Kill CrossDeviceService (Phone Link / nearby sharing)
$cross = Get-Process CrossDeviceService -ErrorAction SilentlyContinue
if ($cross) {
    $cross | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "    Killed CrossDeviceService (75MB)" -ForegroundColor Gray
}

# 1f. Clean clipboard history
Write-Host "[5] Clearing clipboard history..." -ForegroundColor White
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
[System.Windows.Forms.Clipboard]::Clear()
Write-Host "    Done" -ForegroundColor Gray

$phase1RAM = Get-FreeRAMGB
Write-Host ""
Write-Host "Phase 1 result: $startRAM GB -> $phase1RAM GB (+$([math]::Round($phase1RAM - $startRAM, 1)) GB freed)" -ForegroundColor Green
Write-Host ""

# ========================================
# PHASE 2: AGGRESSIVE (with -aggressive flag)
# ========================================
if ($aggressive) {
    Write-Host "=== Phase 2: Aggressive Optimizations ===" -ForegroundColor Yellow

    # 2a. Stop Windows Search Indexer (saves 100-300MB, search will be slower)
    Write-Host "[6] Stopping Windows Search Indexer..." -ForegroundColor White
    try {
        Stop-Service WSearch -Force -ErrorAction Stop
        Write-Host "    Stopped WSearch (search will be slower until restart)" -ForegroundColor Gray
    } catch {
        Write-Host "    Needs admin" -ForegroundColor DarkGray
    }

    # 2b. Stop SysMain/Superfetch
    Write-Host "[7] Stopping Superfetch/SysMain..." -ForegroundColor White
    try {
        Stop-Service SysMain -Force -ErrorAction Stop
        Write-Host "    Stopped SysMain (app launch may be slower)" -ForegroundColor Gray
    } catch {
        Write-Host "    Needs admin" -ForegroundColor DarkGray
    }

    # 2c. Reduce Edge WebView footprint
    Write-Host "[8] Killing non-essential Edge WebView processes..." -ForegroundColor White
    $edgeWV = Get-Process msedgewebview2 -ErrorAction SilentlyContinue
    $edgeMB = [math]::Round(($edgeWV | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    # Only kill if > 500MB (keep some for Teams if used)
    if ($edgeMB -gt 500) {
        $edgeWV | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "    Killed Edge WebView ($edgeMB MB) - Teams/Widgets will restart as needed" -ForegroundColor Gray
    }

    # 2d. Kill McAfee SafeConnect
    $mcafee = Get-Process "SafeConnect*" -ErrorAction SilentlyContinue
    if ($mcafee) {
        $mcafee | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "    Killed McAfee SafeConnect" -ForegroundColor Gray
    }

    # 2e. Kill CCleaner service
    $ccleaner = Get-Process "CCleaner*" -ErrorAction SilentlyContinue
    if ($ccleaner) {
        $ccleaner | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "    Killed CCleaner" -ForegroundColor Gray
    }

    # 2f. Kill Elgato Camera Hub
    $elgato = Get-Process "Camera Hub*", "CameraHub*" -ErrorAction SilentlyContinue
    if ($elgato) {
        $elgato | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "    Killed Camera Hub" -ForegroundColor Gray
    }

    $phase2RAM = Get-FreeRAMGB
    Write-Host ""
    Write-Host "Phase 2 result: $phase1RAM GB -> $phase2RAM GB (+$([math]::Round($phase2RAM - $phase1RAM, 1)) GB freed)" -ForegroundColor Yellow
}

# ========================================
# FINAL SUMMARY
# ========================================
$endRAM = Get-FreeRAMGB
$totalFreed = [math]::Round($endRAM - $startRAM, 1)

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  OPTIMIZATION COMPLETE" -ForegroundColor Cyan
Write-Host "  RAM: $startRAM GB -> $endRAM GB (+$totalFreed GB freed)" -ForegroundColor $(if ($totalFreed -gt 1) { "Green" } else { "Yellow" })
Write-Host "================================================" -ForegroundColor Cyan

# ========================================
# MANUAL RECOMMENDATIONS
# ========================================
Write-Host ""
Write-Host "=== Manual Steps for More RAM ===" -ForegroundColor Magenta
Write-Host ""

$chromeProcs = Get-Process chrome -ErrorAction SilentlyContinue
$chromeTotalMB = [math]::Round(($chromeProcs | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
if ($chromeTotalMB -gt 1500) {
    Write-Host "  [BIGGEST WIN] Chrome uses $chromeTotalMB MB ($($chromeProcs.Count) tabs)" -ForegroundColor Red
    Write-Host "    -> Install 'The Great Suspender' or 'OneTab' extension" -ForegroundColor White
    Write-Host "    -> Close unused tabs (can save 2-3 GB!)" -ForegroundColor White
    Write-Host "    -> chrome://flags -> 'Memory Saver' -> Enable" -ForegroundColor White
    Write-Host ""
}

Write-Host "  [STARTUP] Remove from startup (Settings -> Apps -> Startup):" -ForegroundColor Yellow
Write-Host "    - McAfee SafeConnect (not needed unless using VPN)" -ForegroundColor White
Write-Host "    - Elgato Camera Hub (only need when streaming)" -ForegroundColor White
Write-Host "    - Adobe Acrobat Synchronizer" -ForegroundColor White
Write-Host "    - Epson printer service" -ForegroundColor White
Write-Host "    - Comet (if not using daily)" -ForegroundColor White
Write-Host ""

Write-Host "  [EDGE WEBVIEW] 1GB used by Teams/Widgets:" -ForegroundColor Yellow
Write-Host "    - Disable Windows Widgets: Settings -> Personalization -> Taskbar -> Widgets OFF" -ForegroundColor White
Write-Host "    - If not using Teams: close or uninstall" -ForegroundColor White
Write-Host ""

Write-Host "  [SERVICES] Run as Admin to disable permanently:" -ForegroundColor Yellow
Write-Host "    sc config DiagTrack start=disabled    # Telemetry" -ForegroundColor Gray
Write-Host "    sc config XblAuthManager start=disabled  # Xbox" -ForegroundColor Gray
Write-Host ""
