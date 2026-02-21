<#
.SYNOPSIS
    Session Guardian v1.0 - Unified RAM monitor + Session lifecycle manager
.DESCRIPTION
    Combines RAM watchdog + session cleanup + MCP orphan cleanup into ONE service.
    Runs every 30 seconds and:
    1. Monitors RAM, kills oldest sessions when low
    2. Auto-closes sessions older than MAX_SESSION_HOURS
    3. Cleans orphaned MCP processes (MCPs without a parent Claude session)
    4. Logs everything to file
.USAGE
    Start hidden:   Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File C:\Users\eladj\.claude\scripts\session-guardian.ps1" -WindowStyle Hidden
    Start visible:  powershell -ExecutionPolicy Bypass -File C:\Users\eladj\.claude\scripts\session-guardian.ps1
    Status:         powershell -ExecutionPolicy Bypass -File C:\Users\eladj\.claude\scripts\session-guardian.ps1 -status
#>

param(
    [switch]$status,
    [int]$MaxSessionHours = 4,
    [int]$WarningRAMMB = 2048,
    [int]$CriticalRAMMB = 1024,
    [int]$CheckIntervalSec = 30
)

$ErrorActionPreference = 'SilentlyContinue'
$logDir = "C:\Users\eladj\.claude\logs"
$logFile = "$logDir\session-guardian.log"
$pidFile = "$logDir\guardian-pid.txt"
$stateFile = "$logDir\guardian-state.json"

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# ========================
# LOGGING
# ========================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        "WARN" { Write-Host $line -ForegroundColor Yellow }
        "CRIT" { Write-Host $line -ForegroundColor Red }
        "OK"   { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

# ========================
# STATUS MODE
# ========================

if ($status) {
    $os = Get-CimInstance Win32_OperatingSystem
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $usedPct = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100)

    Write-Host ""
    Write-Host "=== Session Guardian Status ===" -ForegroundColor Cyan
    Write-Host "RAM: $freeGB GB free / $totalGB GB total ($usedPct% used)" -ForegroundColor $(if ($freeGB -gt 3) { "Green" } elseif ($freeGB -gt 1.5) { "Yellow" } else { "Red" })

    # Check if guardian is running
    if (Test-Path $pidFile) {
        $guardianPid = Get-Content $pidFile -Raw
        $guardianPid = $guardianPid.Trim()
        $proc = Get-Process -Id $guardianPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Guardian: RUNNING (PID $guardianPid)" -ForegroundColor Green
        } else {
            Write-Host "Guardian: STOPPED (stale PID file)" -ForegroundColor Red
        }
    } else {
        Write-Host "Guardian: NOT RUNNING" -ForegroundColor Red
    }

    # List Claude sessions
    $sessions = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
        $_.CommandLine -like '*claude*cli*' -or $_.CommandLine -like '*@anthropic*'
    }
    $mcpProcs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
        $_.CommandLine -like '*mcp*' -or
        $_.CommandLine -like '*skill-registry*' -or
        $_.CommandLine -like '*stitch*' -or
        $_.CommandLine -like '*deepwiki*' -or
        $_.CommandLine -like '*octocode*' -or
        $_.CommandLine -like '*context7*' -or
        $_.CommandLine -like '*codex*mcp*' -or
        $_.CommandLine -like '*gemini*index.js*'
    }

    Write-Host ""
    Write-Host "Claude sessions: $($sessions.Count)" -ForegroundColor White
    foreach ($s in $sessions) {
        $ageMins = [math]::Round(((Get-Date) - $s.CreationDate).TotalMinutes)
        $mb = [math]::Round($s.WorkingSetSize / 1MB)
        $ageStr = if ($ageMins -gt 60) { "$([math]::Floor($ageMins/60))h $($ageMins % 60)m" } else { "${ageMins}m" }
        $color = if ($ageMins -gt ($MaxSessionHours * 60)) { "Red" } elseif ($ageMins -gt 120) { "Yellow" } else { "White" }
        Write-Host "  PID $($s.ProcessId) | $mb MB | age: $ageStr" -ForegroundColor $color
    }

    Write-Host "MCP processes: $($mcpProcs.Count)" -ForegroundColor White

    # Show last 5 log lines
    Write-Host ""
    Write-Host "=== Recent Log ===" -ForegroundColor Cyan
    if (Test-Path $logFile) {
        Get-Content $logFile -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
    exit 0
}

# ========================
# HELPERS
# ========================

function Get-FreeRAMMB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1KB)
}

function Get-ClaudeSessions {
    # Find all Claude CLI node processes
    return Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
        ($_.CommandLine -like '*claude*cli*' -or $_.CommandLine -like '*@anthropic*') -and
        $_.CommandLine -notlike '*stream-json*' -and
        $_.CommandLine -notlike '*output-format*'
    } | Sort-Object CreationDate
}

function Get-MCPProcesses {
    return Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
        $_.CommandLine -like '*skill-registry*dist*index.js*' -or
        $_.CommandLine -like '*stitch-mcp*' -or
        $_.CommandLine -like '*mcp-deepwiki*' -or
        $_.CommandLine -like '*octocode*' -or
        $_.CommandLine -like '*playwright*mcp*' -or
        $_.CommandLine -like '*codex*bin*codex*mcp*' -or
        $_.CommandLine -like '*mcp-server.cjs*' -or
        $_.CommandLine -like '*gemini*index.js*' -or
        $_.CommandLine -like '*context7*'
    }
}

function Get-SessionChildren {
    param([int]$ParentPid)
    # Find child processes of a given PID (MCP servers spawned by Claude)
    return Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ParentPid }
}

function Stop-SessionWithChildren {
    param([object]$Session)
    $pid = $Session.ProcessId
    $mb = [math]::Round($Session.WorkingSetSize / 1MB)
    $age = [math]::Round(((Get-Date) - $Session.CreationDate).TotalMinutes)

    # Kill child processes first (MCP servers)
    $children = Get-SessionChildren -ParentPid $pid
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }

    # Kill the session itself
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    Write-Log "Killed session PID $pid ($mb MB, ${age}min old) + $($children.Count) children" "WARN"
}

function Clean-OrphanMCPs {
    # Find MCP processes whose parent Claude session no longer exists
    $claudePids = (Get-ClaudeSessions).ProcessId
    $mcps = Get-MCPProcesses
    $orphanCount = 0

    foreach ($mcp in $mcps) {
        $parentExists = $claudePids -contains $mcp.ParentProcessId
        if (-not $parentExists) {
            # Check if parent of parent exists (sometimes there's cmd in between)
            $parentProc = Get-CimInstance Win32_Process -Filter "ProcessId=$($mcp.ParentProcessId)" -ErrorAction SilentlyContinue
            if (-not $parentProc -or ($parentProc.Name -ne 'node.exe' -and $parentProc.Name -ne 'cmd.exe')) {
                Stop-Process -Id $mcp.ProcessId -Force -ErrorAction SilentlyContinue
                $orphanCount++
            }
        }
    }

    if ($orphanCount -gt 0) {
        Write-Log "Cleaned $orphanCount orphaned MCP processes" "OK"
    }
    return $orphanCount
}

# ========================
# TRIM LOG (keep last 500 lines)
# ========================

function Trim-Log {
    if (Test-Path $logFile) {
        $lines = Get-Content $logFile -ErrorAction SilentlyContinue
        if ($lines.Count -gt 500) {
            $lines | Select-Object -Last 500 | Set-Content $logFile -ErrorAction SilentlyContinue
        }
    }
}

# ========================
# MAIN LOOP
# ========================

# Write PID file so we can check if guardian is running
Set-Content -Path $pidFile -Value $PID -ErrorAction SilentlyContinue

Write-Log "Session Guardian v1.0 started (warn: ${WarningRAMMB}MB, crit: ${CriticalRAMMB}MB, maxAge: ${MaxSessionHours}h, interval: ${CheckIntervalSec}s)"

$loopCount = 0

while ($true) {
    try {
    $loopCount++
    $freeRAM = Get-FreeRAMMB
    $sessions = @()
    $sessionResult = Get-ClaudeSessions
    if ($sessionResult) { $sessions = @($sessionResult) }

    # === 1. CRITICAL RAM: Kill all except newest ===
    if ($freeRAM -lt $CriticalRAMMB) {
        Write-Log "CRITICAL: Only $freeRAM MB free! Emergency cleanup..." "CRIT"

        if ($sessions.Count -gt 1) {
            # Kill all except the newest session
            for ($i = 0; $i -lt $sessions.Count - 1; $i++) {
                Stop-SessionWithChildren -Session $sessions[$i]
            }
        }

        # Also kill orphan MCPs and dev servers
        Clean-OrphanMCPs

        # Kill dev servers
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
            $_.CommandLine -like '*next*dist*bin*next*' -or
            $_.CommandLine -like '*vite*serve*'
        } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log "  Killed dev server PID $($_.ProcessId)" "CRIT"
        }

        # Kill bun processes
        Get-Process bun -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # === 2. WARNING RAM: Kill oldest session ===
    elseif ($freeRAM -lt $WarningRAMMB) {
        Write-Log "WARNING: $freeRAM MB free. Cleaning up..." "WARN"

        # First try orphan MCPs
        $cleaned = Clean-OrphanMCPs

        # If still low, kill oldest session
        $freeRAM2 = Get-FreeRAMMB
        if ($freeRAM2 -lt $WarningRAMMB -and $sessions.Count -gt 1) {
            Stop-SessionWithChildren -Session $sessions[0]
        }
    }

    # === 3. SESSION TIMEOUT: Kill sessions older than max hours ===
    $maxAgeMinutes = $MaxSessionHours * 60
    foreach ($session in $sessions) {
        $ageMins = ((Get-Date) - $session.CreationDate).TotalMinutes
        if ($ageMins -gt $maxAgeMinutes) {
            Write-Log "Session PID $($session.ProcessId) exceeded max age ($([math]::Round($ageMins))min > ${maxAgeMinutes}min)" "WARN"
            Stop-SessionWithChildren -Session $session
        }
    }

    # === 4. ORPHAN MCP CLEANUP (every 5 minutes) ===
    if ($loopCount % 10 -eq 0) {
        Clean-OrphanMCPs
    }

    # === 5. STATE FILE (for dashboard/status) ===
    if ($loopCount % 6 -eq 0) {  # Every 3 minutes
        $state = @{
            lastCheck = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            freeRAMMB = $freeRAM
            sessionCount = $sessions.Count
            mcpCount = (Get-MCPProcesses).Count
            pid = $PID
        } | ConvertTo-Json
        Set-Content -Path $stateFile -Value $state -ErrorAction SilentlyContinue
    }

    # === 6. TRIM LOG (every hour) ===
    if ($loopCount % 120 -eq 0) {
        Trim-Log
    }

    } catch {
        # Log any errors but keep running
        $errMsg = $_.Exception.Message
        Write-Log "Loop error: $errMsg" "WARN"
    }

    Start-Sleep -Seconds $CheckIntervalSec
}
