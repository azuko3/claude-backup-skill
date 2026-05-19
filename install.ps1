# install.ps1 — one-time setup for claude-bak on Windows
# Run from PowerShell: .\install.ps1
#
# What this script does (nothing hidden):
#   1. Copies scripts/claude-bak.ps1 to %USERPROFILE%\AppData\Local\Microsoft\WindowsApps\
#   2. Creates a claude-bak.cmd wrapper so the command works in any terminal
#   3. Checks your PowerShell ExecutionPolicy and warns if scripts are restricted
#   4. Optionally registers a daily Task Scheduler job at 09:00
#   5. Runs: claude-bak status (read-only)
#
# What it does NOT do:
#   - Does not modify %USERPROFILE%\.claude or any Claude files
#   - Does not make network requests
#   - Does not read your API keys or credentials
#   - Does not run any backup automatically
#
# To review before running:
#   Get-Content install.ps1
#   Get-Content scripts\claude-bak.ps1
#
# If you get "running scripts is disabled", run first:
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

param([switch]$DryRun)

$ScriptDir     = Split-Path $MyInvocation.MyCommand.Path
$ScriptSrc     = Join-Path $ScriptDir "scripts\claude-bak.ps1"
$BinDir        = Join-Path $env:USERPROFILE "AppData\Local\Microsoft\WindowsApps"
$BinTarget     = Join-Path $BinDir "claude-bak.ps1"
$WrapperTarget = Join-Path $BinDir "claude-bak.cmd"

if ($DryRun) {
    Write-Host "[dry-run] What install.ps1 would do:" -ForegroundColor White
    Write-Host "  Copy $ScriptSrc → $BinTarget"
    Write-Host "  Create wrapper → $WrapperTarget"
    Write-Host "  (optionally) Register Task Scheduler job: claude-bak backup all -Tag daily at 09:00"
    Write-Host ""
    Write-Host "Nothing was changed. Run without -DryRun to install." -ForegroundColor DarkGray
    exit 0
}

Write-Host "Installing claude-bak ..." -ForegroundColor White

# ── os check ─────────────────────────────────────────────────────────────────
if ($env:OS -ne "Windows_NT") {
    Write-Host "✗ This installer is for Windows. On macOS run: bash install.sh" -ForegroundColor Red
    exit 1
}

# ── copy script ──────────────────────────────────────────────────────────────
if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Path $BinDir -Force | Out-Null }
Copy-Item $ScriptSrc $BinTarget -Force
Write-Host "✓ Installed → $BinTarget" -ForegroundColor Green

# ── create cmd wrapper ───────────────────────────────────────────────────────
@"
@echo off
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\AppData\Local\Microsoft\WindowsApps\claude-bak.ps1" %*
"@ | Set-Content $WrapperTarget
Write-Host "✓ Wrapper created → $WrapperTarget" -ForegroundColor Green
Write-Host "  You can now type 'claude-bak' in any terminal window."

# ── execution policy check ───────────────────────────────────────────────────
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq "Restricted" -or $policy -eq "Undefined") {
    Write-Host ""
    Write-Host "⚠  PowerShell scripts are restricted on your machine." -ForegroundColor Yellow
    Write-Host "   Run this once to allow them:" -ForegroundColor Yellow
    Write-Host "   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned" -ForegroundColor Cyan
}

# ── optional daily backup via Task Scheduler ─────────────────────────────────
Write-Host ""
$answer = Read-Host "Set up a daily automatic backup? [y/N]"
if ($answer.ToLower() -eq "y") {
    $taskName = "ClaudeDailyBackup"
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "⚠  Scheduled task already exists — skipping" -ForegroundColor Yellow
    } else {
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-ExecutionPolicy Bypass -File `"$BinTarget`" backup all -Tag daily"
        $trigger = New-ScheduledTaskTrigger -Daily -At "09:00"
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -RunLevel Limited -Force | Out-Null
        Write-Host "✓ Daily backup scheduled at 09:00 (Task Scheduler)" -ForegroundColor Green
    }
} else {
    Write-Host "  Skipped. You can set it up later via Task Scheduler."
}

# ── initial status ────────────────────────────────────────────────────────────
Write-Host ""
& powershell -ExecutionPolicy Bypass -File $BinTarget status

Write-Host ""
Write-Host "Done! Run 'claude-bak backup' to create your first snapshot." -ForegroundColor White
