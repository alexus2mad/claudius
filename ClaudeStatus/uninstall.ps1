#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the Claude Code LCD status system from this PC.

.DESCRIPTION
    - Stops the running daemon if alive (graceful exit-file first; a hard
      kill can wedge the CH340 serial chip until the device is replugged).
    - Unregisters the "ClaudeStatusDaemon" Task Scheduler entry.
    - Restores ~/.claude/settings.json from the .claudestatus_backup that
      setup.ps1 wrote (or, if no backup exists, removes the five hooks
      we added by command-path match).
    - Deletes %LOCALAPPDATA%\ClaudeStatus.
    - Does NOT touch Python, Node, pyserial, or the Arduino firmware.
      (Re-flash the Uno with its previous sketch yourself if needed.)
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$installDir   = Join-Path $env:LOCALAPPDATA 'ClaudeStatus'
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$backupPath   = "$settingsPath.claudestatus_backup"
$pidFile      = Join-Path $env:TEMP 'claude_lcd_daemon.pid'
$stateFile    = Join-Path $env:TEMP 'claude_lcd_state.txt'
$logFile      = Join-Path $env:TEMP 'claude_lcd_daemon.log'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" }
function Done($msg) { Write-Host "    OK: $msg" -ForegroundColor Green }

# 1. Stop daemon — graceful exit-file first ($pid is a reserved automatic
# variable in PowerShell, hence $dpid). Force-kill only as a last resort:
# it can wedge the CH340's open handle until the device is replugged.
Step "Stopping daemon"
$exitFile = Join-Path $env:TEMP 'claude_lcd_daemon.exit'
if (Test-Path $pidFile) {
    $dpid = 0
    try { $dpid = [int](Get-Content $pidFile -Raw).Trim() } catch {}
    if ($dpid -gt 0 -and (Get-Process -Id $dpid -ErrorAction SilentlyContinue)) {
        New-Item -ItemType File -Path $exitFile -Force | Out-Null
        foreach ($i in 1..25) {
            Start-Sleep -Milliseconds 200
            if (-not (Get-Process -Id $dpid -ErrorAction SilentlyContinue)) { break }
        }
        if (Get-Process -Id $dpid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $dpid -Force -ErrorAction SilentlyContinue
            Info "Force-killed pid $dpid (replug the device if its port misbehaves)"
        } else {
            Info "Daemon pid $dpid exited cleanly"
        }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}
Remove-Item $exitFile  -ErrorAction SilentlyContinue
Remove-Item $stateFile -ErrorAction SilentlyContinue
Remove-Item $logFile   -ErrorAction SilentlyContinue
Done "Daemon stopped"

# 2. Unregister Task Scheduler entry
Step "Removing Task Scheduler entry"
try {
    Unregister-ScheduledTask -TaskName 'ClaudeStatusDaemon' -Confirm:$false -ErrorAction Stop
    Done "Auto-start task removed"
} catch {
    Info "(no task registered)"
}

# 3. Settings.json: restore backup if present, else strip our hooks
Step "Restoring ~/.claude/settings.json"
if (Test-Path $backupPath) {
    Copy-Item $backupPath $settingsPath -Force
    Remove-Item $backupPath
    Done "Restored from backup"
} elseif (Test-Path $settingsPath) {
    $raw = Get-Content $settingsPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $obj = $raw | ConvertFrom-Json
        if ($obj.PSObject.Properties.Match('hooks')) {
            $needle = (Join-Path $installDir 'app').Replace('\','/')
            foreach ($evt in @('UserPromptSubmit','PreToolUse','PostToolUse','Notification','Stop')) {
                $entries = $obj.hooks.$evt
                if ($entries) {
                    $kept = @()
                    foreach ($block in $entries) {
                        $keep = $true
                        foreach ($h in $block.hooks) {
                            if ($h.command -and $h.command -like "*$needle*") { $keep = $false }
                        }
                        if ($keep) { $kept += $block }
                    }
                    if ($kept.Count -gt 0) {
                        $obj.hooks.$evt = $kept
                    } else {
                        $obj.hooks.PSObject.Properties.Remove($evt)
                    }
                }
            }
            if ($obj.hooks.PSObject.Properties.Count -eq 0) {
                $obj.PSObject.Properties.Remove('hooks')
            }
        }
        ($obj | ConvertTo-Json -Depth 30) | Set-Content -Path $settingsPath -Encoding UTF8
        Done "Hooks stripped by path match"
    }
} else {
    Info "(no settings.json found)"
}

# 4. Delete install dir
Step "Removing $installDir"
if (Test-Path $installDir) {
    Remove-Item $installDir -Recurse -Force
    Done "Files removed"
} else {
    Info "(already gone)"
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host ""
