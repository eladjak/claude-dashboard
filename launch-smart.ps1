<#
.SYNOPSIS
    Smart Claude Code Multi-Project Launcher v6.0
    Launches projects in Windows Terminal tabs with RAM monitoring

.DESCRIPTION
    - Launches Claude Code sessions in Windows Terminal tabs
    - Checks RAM before each launch, refuses if <3GB free
    - Creates wrapper scripts that clean up child processes on exit
    - Supports tiers: --daily (default), --weekly, --extras, --all
    - Tracks PIDs for kill-all support

.USAGE
    powershell -File launch-smart.ps1                 # Daily projects (2-3)
    powershell -File launch-smart.ps1 --weekly        # Weekly projects
    powershell -File launch-smart.ps1 --extras        # Extra projects
    powershell -File launch-smart.ps1 --kill          # Kill all running sessions
    powershell -File launch-smart.ps1 --status        # Show running sessions
#>

param(
    [switch]$weekly,
    [switch]$extras,
    [switch]$all,
    [switch]$kill,
    [switch]$status,
    [int]$maxSessions = 3,
    [int]$minFreeRAMGB = 3
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$claudePath = "C:\Users\eladj\AppData\Roaming\npm\claude.cmd"
$pidFile = "C:\Users\eladj\.claude\logs\active-sessions.json"
$wrapperDir = "C:\Users\eladj\.claude\scripts\wrappers"
$promptDir = "C:\Users\eladj\.claude\scripts\prompts"

# Ensure directories exist
if (-not (Test-Path $wrapperDir)) { New-Item -ItemType Directory -Path $wrapperDir -Force | Out-Null }
if (-not (Test-Path "C:\Users\eladj\.claude\logs")) { New-Item -ItemType Directory -Path "C:\Users\eladj\.claude\logs" -Force | Out-Null }

# ========================
# PROJECT DEFINITIONS
# ========================

$dailyProjects = @(
    @{
        Name = "BayitBeSeder"
        Path = "C:\Users\eladj\projects\bayit-beseder"
        Color = "#e91e63"
        PromptFile = "3-bayit-beseder.txt"
    },
    @{
        Name = "Kami"
        Path = "C:\Users\eladj\projects\elad-personal-agent"
        Color = "#9c27b0"
        PromptFile = "4-kami-agent.txt"
    },
    @{
        Name = "EitanEvents"
        Path = "C:\Users\eladj\projects\eitan-events"
        Color = "#ff9800"
        PromptFile = "10-eitan-events.txt"
    }
)

$weeklyProjects = @(
    @{
        Name = "DateKirva"
        Path = "C:\Users\eladj\projects\date-kirva"
        Color = "#f48fb1"
        PromptFile = "24-date-kirva.txt"
    },
    @{
        Name = "Portfolio"
        Path = "C:\Users\eladj\projects\portfolio-website"
        Color = "#2196f3"
        PromptFile = "6-portfolio.txt"
    },
    @{
        Name = "Omanut"
        Path = "C:\Users\eladj\projects\omanut-hakesher-website"
        Color = "#4caf50"
        PromptFile = "8-omanut-website.txt"
    }
)

$extrasProjects = @(
    @{
        Name = "EduTech"
        Path = "C:\Users\eladj\projects\edutech"
        Color = "#00bcd4"
        PromptFile = "11-edutech.txt"
    },
    @{
        Name = "NinjaKeyboard"
        Path = "C:\Users\eladj\projects\ninja-keyboard"
        Color = "#607d8b"
        PromptFile = "18-ninja-keyboard.txt"
    }
)

# ========================
# HELPER FUNCTIONS
# ========================

function Get-FreeRAMGB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1MB, 1)
}

function Get-ActiveSessionCount {
    $nodeCount = (Get-Process node -ErrorAction SilentlyContinue | Where-Object {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        $cmd -like '*claude-code/cli.js*'
    } | Measure-Object).Count
    # Each Claude session typically has 1-2 main node processes
    return [math]::Ceiling($nodeCount / 2)
}

function Write-SessionStatus {
    $freeRAM = Get-FreeRAMGB
    $sessions = Get-ActiveSessionCount
    $color = if ($freeRAM -gt 4) { "Green" } elseif ($freeRAM -gt 2) { "Yellow" } else { "Red" }
    Write-Host "RAM: $freeRAM GB free | Active sessions: ~$sessions" -ForegroundColor $color
}

function Stop-AllSessions {
    Write-Host "Stopping all Claude sessions..." -ForegroundColor Yellow

    # Run the cleanup script
    $cleanupScript = "C:\Users\eladj\.claude\scripts\cleanup-all.ps1"
    if (Test-Path $cleanupScript) {
        & $cleanupScript
    } else {
        # Inline cleanup
        Get-Process claude -ErrorAction SilentlyContinue | Stop-Process -Force
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
            $_.CommandLine -like '*claude-code/cli.js*' -or
            $_.CommandLine -like '*skill-registry*' -or
            $_.CommandLine -like '*mcp*'
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }

    # Clean wrapper scripts
    if (Test-Path $wrapperDir) {
        Remove-Item "$wrapperDir\*.cmd" -Force -ErrorAction SilentlyContinue
    }

    Write-Host "All sessions stopped." -ForegroundColor Green
}

function New-WrapperScript {
    param([string]$ProjectName, [string]$ProjectPath, [string]$Prompt)

    $wrapperPath = "$wrapperDir\$ProjectName.cmd"

    # Create a wrapper that runs Claude and cleans up on exit
    $content = @"
@echo off
title Claude: $ProjectName
cd /d "$ProjectPath"
echo.
echo ============================================
echo   Claude Code: $ProjectName
echo   Path: $ProjectPath
echo   Started: %date% %time%
echo ============================================
echo.
echo [Starting Claude Code session...]
echo.

"$claudePath" --permission-mode bypassPermissions -p "$($Prompt -replace '"', '\"')"

echo.
echo [Session ended. Cleaning up child processes...]

:: Kill any dev servers started by this session in this directory
for /f "tokens=2" %%i in ('tasklist /fi "WINDOWTITLE eq Claude: $ProjectName" 2^>nul ^| findstr /i node') do (
    taskkill /pid %%i /f >nul 2>&1
)

echo [Cleanup complete. Press any key to close.]
pause >nul
"@

    Set-Content -Path $wrapperPath -Value $content -Encoding ASCII
    return $wrapperPath
}

# ========================
# MAIN LOGIC
# ========================

# Handle --kill
if ($kill) {
    Stop-AllSessions
    exit 0
}

# Handle --status
if ($status) {
    Write-Host ""
    Write-Host "=== SESSION STATUS ===" -ForegroundColor Cyan
    Write-SessionStatus
    Write-Host ""

    $claudeNodes = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
        $_.CommandLine -like '*claude-code/cli.js*' -and $_.CommandLine -notlike '*stream-json*'
    }
    if ($claudeNodes) {
        Write-Host "Active Claude sessions:" -ForegroundColor White
        foreach ($p in $claudeNodes) {
            $mb = [math]::Round($p.WorkingSetSize/1MB)
            $started = $p.CreationDate
            Write-Host "  PID $($p.ProcessId) [$mb MB] started $started"
        }
    } else {
        Write-Host "No active Claude sessions" -ForegroundColor Gray
    }
    exit 0
}

# Select projects based on tier
$projects = @()
if ($all) {
    $projects = $dailyProjects + $weeklyProjects + $extrasProjects
} elseif ($weekly) {
    $projects = $weeklyProjects
} elseif ($extras) {
    $projects = $extrasProjects
} else {
    $projects = $dailyProjects
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SMART LAUNCHER v6.0" -ForegroundColor Cyan
Write-Host "  Projects: $($projects.Count) | Max concurrent: $maxSessions" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Ensure Session Guardian is running
$guardianPidFile = "C:\Users\eladj\.claude\logs\guardian-pid.txt"
$guardianRunning = $false
if (Test-Path $guardianPidFile) {
    $gpid = (Get-Content $guardianPidFile -Raw).Trim()
    $gproc = Get-Process -Id $gpid -ErrorAction SilentlyContinue
    if ($gproc) { $guardianRunning = $true }
}
if (-not $guardianRunning) {
    Write-Host "  Starting Session Guardian..." -ForegroundColor Yellow
    Start-Process wscript.exe -ArgumentList "C:\Users\eladj\.claude\scripts\start-guardian.vbs"
    Start-Sleep -Seconds 2
    Write-Host "  Session Guardian started" -ForegroundColor Green
} else {
    Write-Host "  Session Guardian: RUNNING" -ForegroundColor Green
}

# Pre-flight RAM check
$freeRAM = Get-FreeRAMGB
Write-Host "Pre-flight check:" -ForegroundColor White
Write-Host "  RAM available: $freeRAM GB (minimum: $minFreeRAMGB GB)" -ForegroundColor $(if ($freeRAM -ge $minFreeRAMGB) { "Green" } else { "Red" })

if ($freeRAM -lt $minFreeRAMGB) {
    Write-Host ""
    Write-Host "  WARNING: Not enough RAM! Running cleanup first..." -ForegroundColor Red
    Stop-AllSessions
    Start-Sleep -Seconds 3
    $freeRAM = Get-FreeRAMGB
    Write-Host "  RAM after cleanup: $freeRAM GB" -ForegroundColor $(if ($freeRAM -ge $minFreeRAMGB) { "Green" } else { "Red" })

    if ($freeRAM -lt $minFreeRAMGB) {
        Write-Host "  ABORT: Still not enough RAM. Close other applications and try again." -ForegroundColor Red
        exit 1
    }
}

Write-Host ""

# Launch projects
$launched = 0
$firstTab = $true

foreach ($project in $projects) {
    # RAM check before each launch
    $freeRAM = Get-FreeRAMGB
    if ($freeRAM -lt $minFreeRAMGB) {
        Write-Host "  STOP: RAM dropped to $freeRAM GB. Skipping remaining projects." -ForegroundColor Red
        break
    }

    # Session limit check
    if ($launched -ge $maxSessions) {
        Write-Host "  STOP: Reached max concurrent sessions ($maxSessions). Skipping remaining." -ForegroundColor Yellow
        break
    }

    # Read prompt from file
    $promptPath = "$promptDir\$($project.PromptFile)"
    $prompt = ""
    if (Test-Path $promptPath) {
        $prompt = Get-Content $promptPath -Raw -Encoding UTF8
        $prompt = $prompt.Trim()
    } else {
        $prompt = "Read CLAUDE.md + PROGRESS.md first. Check current state and continue work. Use Context7 + Octocode MCPs for API docs. Commit significant changes."
    }

    # Create wrapper script
    $wrapper = New-WrapperScript -ProjectName $project.Name -ProjectPath $project.Path -Prompt $prompt

    # Launch in Windows Terminal tab
    if ($firstTab) {
        # First project: new window
        Start-Process wt -ArgumentList "new-tab", "--title", $project.Name, "--tabColor", $project.Color, "-d", $project.Path, "cmd", "/k", "`"$wrapper`""
        $firstTab = $false
    } else {
        # Subsequent projects: new tab in existing window
        Start-Sleep -Seconds 2
        Start-Process wt -ArgumentList "-w", "0", "new-tab", "--title", $project.Name, "--tabColor", $project.Color, "-d", $project.Path, "cmd", "/k", "`"$wrapper`""
    }

    $launched++
    $ramNow = Get-FreeRAMGB
    Write-Host "  [$launched/$($projects.Count)] $($project.Name) - launched (RAM: $ramNow GB free)" -ForegroundColor Green

    # Wait between launches to let MCP servers stabilize
    if ($launched -lt $projects.Count) {
        Start-Sleep -Seconds 5
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  LAUNCHED $launched PROJECTS" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Windows Terminal Controls:" -ForegroundColor White
Write-Host "  Ctrl+Tab         - Switch between tabs" -ForegroundColor Gray
Write-Host "  Ctrl+Shift+W     - Close current tab" -ForegroundColor Gray
Write-Host "  Ctrl+Shift+T     - New tab" -ForegroundColor Gray
Write-Host "  Alt+Shift+D      - Split pane" -ForegroundColor Gray
Write-Host "  Drag tab out      - Detach to separate window" -ForegroundColor Gray
Write-Host "  Right-click tab  - Full menu (rename, color, close)" -ForegroundColor Gray
Write-Host ""
Write-Host "Management:" -ForegroundColor White
Write-Host "  powershell -File launch-smart.ps1 --status  - Check status" -ForegroundColor Gray
Write-Host "  powershell -File launch-smart.ps1 --kill    - Kill all sessions" -ForegroundColor Gray
Write-Host ""
