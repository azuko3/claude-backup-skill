# claude-bak.ps1 — backup, restore, and sync Claude state on Windows
# Requires: PowerShell 5.1+ (built into Windows 10/11)
#
# Usage: claude-bak <command> [options]
#   backup  [all|code|desktop] [-Tag <name>]
#   restore [all|code|desktop] [snapshot-id|latest]
#   list
#   status
#   sync    push|pull [-Remote <url>]
#   setup   local|git

[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$Command = "",
    [Parameter(Position=1)] [string]$Arg1 = "",
    [Parameter(Position=2)] [string]$Arg2 = "",
    [string]$Tag = "",
    [string]$Remote = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── constants ───────────────────────────────────────────────────────────────
$CLAUDE_CODE_DIR    = Join-Path $env:USERPROFILE ".claude"
$CLAUDE_DESKTOP_DIR = Join-Path $env:APPDATA "Claude"
$BACKUP_ROOT        = Join-Path $env:USERPROFILE "backups\claude"
$CONFIG_FILE        = Join-Path $BACKUP_ROOT ".claude-bak.conf.json"
$MAX_SNAPSHOTS      = 10

# ─── helpers ─────────────────────────────────────────────────────────────────
function Log  { param($msg) Write-Host "▶ $msg" -ForegroundColor Blue }
function Ok   { param($msg) Write-Host "✓ $msg" -ForegroundColor Green }
function Warn { param($msg) Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Err  { param($msg) Write-Host "✗ $msg" -ForegroundColor Red }
function Die  { param($msg) Err $msg; exit 1 }

function Require-Windows {
    if ($env:OS -ne "Windows_NT") {
        Die "claude-bak.ps1 requires Windows. On macOS use: claude-bak (the bash version)"
    }
}

function Load-Config {
    $script:GIT_REMOTE = ""
    $script:BACKEND = "local"
    if (Test-Path $CONFIG_FILE) {
        $cfg = Get-Content $CONFIG_FILE | ConvertFrom-Json
        if ($cfg.PSObject.Properties["git_remote"]) { $script:GIT_REMOTE = $cfg.git_remote }
        if ($cfg.PSObject.Properties["backend"])    { $script:BACKEND    = $cfg.backend }
    }
}

function Save-Config {
    if (-not (Test-Path $BACKUP_ROOT)) { New-Item -ItemType Directory -Path $BACKUP_ROOT -Force | Out-Null }
    @{ backend = $script:BACKEND; git_remote = $script:GIT_REMOTE } | ConvertTo-Json | Set-Content $CONFIG_FILE
}

function Human-Size { param($path)
    if (-not (Test-Path $path)) { return "0B" }
    $bytes = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $bytes -or $bytes -eq 0) { return "0B" }
    switch ($bytes) {
        { $_ -gt 1GB } { return "{0:N1}GB" -f ($_ / 1GB) }
        { $_ -gt 1MB } { return "{0:N1}MB" -f ($_ / 1MB) }
        { $_ -gt 1KB } { return "{0:N1}KB" -f ($_ / 1KB) }
        default { return "${bytes}B" }
    }
}

function Count-Files { param($path)
    if (-not (Test-Path $path)) { return 0 }
    (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue).Count
}

function Snapshot-Id {
    Get-Date -Format "yyyyMMdd-HHmmss"
}

function List-Snapshots {
    if (-not (Test-Path $BACKUP_ROOT)) { return @() }
    Get-ChildItem $BACKUP_ROOT -Directory |
        Where-Object { $_.Name -notmatch '^\.' } |
        Sort-Object Name -Descending |
        Select-Object -ExpandProperty FullName
}

# dirs and patterns to skip when copying Desktop
$DESKTOP_EXCLUDES = @(
    "Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
    "Crashpad", "blob_storage", "sentry", "vm_bundles", "claude-code-vm", "claude-code",
    "DIPS", "SharedStorage", "InterestGroups", "WebStorage", "Session Storage",
    "Trust Tokens", "Shared Dictionary", "Partitions", "Network Persistent State",
    "TransportSecurity", "Cookies", "Cookies-journal"
)

$CODE_EXCLUDES = @("cache", "telemetry", "downloads")

function Robocopy-Filtered {
    param([string]$src, [string]$dest, [string[]]$excludeDirs)
    $xd = $excludeDirs | ForEach-Object { "`"$_`"" }
    $excludeArg = if ($xd.Count -gt 0) { "/XD $($xd -join ' ')" } else { "" }
    $cmd = "robocopy `"$src`" `"$dest`" /E /NP /NFL /NDL /NJH /NJS $excludeArg"
    Invoke-Expression $cmd | Out-Null
    # robocopy exits 1 for success-with-copies, 0 for no change — both are fine
    if ($LASTEXITCODE -gt 7) { Warn "robocopy reported errors (exit $LASTEXITCODE)" }
}

function Write-Manifest {
    param([string]$snapDir, [string]$tag)
    $files = Get-ChildItem $snapDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "manifest.json" } |
        ForEach-Object { $_.FullName.Replace($snapDir + "\", "") }
    $totalBytes = ($files | ForEach-Object {
        (Get-Item (Join-Path $snapDir $_) -ErrorAction SilentlyContinue).Length
    } | Measure-Object -Sum).Sum
    $totalMb = [math]::Round($totalBytes / 1MB, 1)
    $manifest = @{
        created    = (Get-Date -Format "o")
        os_version = (Get-WmiObject Win32_OperatingSystem).Caption
        tag        = $tag
        total_mb   = $totalMb
        file_count = $files.Count
    }
    $manifest | ConvertTo-Json | Set-Content (Join-Path $snapDir "manifest.json")
    Write-Host "  files: $($files.Count), size: ${totalMb}MB"
}

function Rotate-Snapshots {
    $snaps = List-Snapshots
    if ($snaps.Count -gt $MAX_SNAPSHOTS) {
        $toDelete = $snaps.Count - $MAX_SNAPSHOTS
        Log "Rotating: removing $toDelete old snapshot(s)"
        $snaps | Select-Object -Last $toDelete | ForEach-Object {
            Remove-Item $_ -Recurse -Force
            Write-Host "  removed: $(Split-Path $_ -Leaf)"
        }
    }
}

# ─── backup ──────────────────────────────────────────────────────────────────
function Do-Backup {
    param([string]$target = "all", [string]$tag = "")
    Require-Windows
    Load-Config

    $id = Snapshot-Id
    if ($tag) { $id = "$id-$tag" }
    $snapDir = Join-Path $BACKUP_ROOT $id

    if (-not (Test-Path $BACKUP_ROOT)) { New-Item -ItemType Directory -Path $BACKUP_ROOT -Force | Out-Null }

    Log "Creating snapshot: $id"

    if ($target -eq "all" -or $target -eq "code") {
        Log "Backing up Claude Code (~\.claude) …"
        $dest = Join-Path $snapDir "code"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Robocopy-Filtered $CLAUDE_CODE_DIR $dest $CODE_EXCLUDES
        Ok "Code: $(Count-Files $dest) files ($(Human-Size $dest))"
    }

    if ($target -eq "all" -or $target -eq "desktop") {
        Log "Backing up Claude Desktop …"
        if (-not (Test-Path $CLAUDE_DESKTOP_DIR)) {
            Warn "Claude Desktop directory not found — skipping"
        } else {
            $claudeProc = Get-Process "Claude" -ErrorAction SilentlyContinue
            if ($claudeProc) { Warn "Claude Desktop is running — backup will proceed but data may be inconsistent" }
            $dest = Join-Path $snapDir "desktop"
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Robocopy-Filtered $CLAUDE_DESKTOP_DIR $dest $DESKTOP_EXCLUDES
            Ok "Desktop: $(Count-Files $dest) files ($(Human-Size $dest))"
        }
    }

    Log "Writing manifest …"
    Write-Manifest $snapDir $tag
    Rotate-Snapshots

    if ($script:BACKEND -eq "git" -and $script:GIT_REMOTE) {
        Log "Pushing to git remote …"
        git -C $BACKUP_ROOT add -A 2>$null
        git -C $BACKUP_ROOT commit -m "snapshot $id" --quiet 2>$null
        git -C $BACKUP_ROOT push --quiet 2>$null
        if ($LASTEXITCODE -eq 0) { Ok "Pushed to $($script:GIT_REMOTE)" }
        else { Warn "Git push failed — run: claude-bak sync push" }
    }

    Ok "Snapshot saved → $snapDir"
    Write-Host ""
    Write-Host "  ID: $id" -ForegroundColor White
    if ($tag) { Write-Host "  Tag: $tag" -ForegroundColor White }
}

# ─── restore ─────────────────────────────────────────────────────────────────
function Do-Restore {
    param([string]$target = "all", [string]$snapArg = "latest")
    Require-Windows
    Load-Config

    $snapDir = ""
    if ($snapArg -eq "latest") {
        $snaps = List-Snapshots
        if ($snaps.Count -eq 0) { Die "No snapshots found. Run: claude-bak backup" }
        $snapDir = $snaps[0]
    } else {
        $snapDir = Join-Path $BACKUP_ROOT $snapArg
        if (-not (Test-Path $snapDir)) {
            Err "Snapshot '$snapArg' not found."
            Write-Host "Available snapshots:"
            Do-List
            exit 1
        }
    }

    $snapId = Split-Path $snapDir -Leaf
    Log "Restoring from snapshot: $snapId"
    Log "Creating safety backup of current state …"
    Do-Backup $target "pre-restore"

    Write-Host ""
    Write-Host "This will overwrite your current Claude state with snapshot: $snapId" -ForegroundColor Yellow
    $answer = Read-Host "Continue? [y/N]"
    if ($answer.ToLower() -ne "y") { Log "Aborted."; exit 0 }

    if ($target -eq "all" -or $target -eq "code") {
        $src = Join-Path $snapDir "code"
        if (Test-Path $src) {
            Log "Restoring Claude Code …"
            Robocopy-Filtered $src $CLAUDE_CODE_DIR @()
            Ok "Code restored"
        } else { Warn "No code backup in this snapshot" }
    }

    if ($target -eq "all" -or $target -eq "desktop") {
        $src = Join-Path $snapDir "desktop"
        if (Test-Path $src) {
            $claudeProc = Get-Process "Claude" -ErrorAction SilentlyContinue
            if ($claudeProc) {
                Warn "Claude Desktop is running — quit it first for a clean restore"
                $answer2 = Read-Host "Proceed anyway? [y/N]"
                if ($answer2.ToLower() -ne "y") { Log "Aborted."; exit 0 }
            }
            Log "Restoring Claude Desktop …"
            Robocopy-Filtered $src $CLAUDE_DESKTOP_DIR @()
            Ok "Desktop restored"
        } else { Warn "No desktop backup in this snapshot" }
    }

    Ok "Restore complete from: $snapId"
}

# ─── list ─────────────────────────────────────────────────────────────────────
function Do-List {
    $snaps = List-Snapshots
    if ($snaps.Count -eq 0) {
        Write-Host "No snapshots found. Run: claude-bak backup"
        return
    }

    Write-Host ""
    Write-Host ("{0,-28} {1,-22} {2,-10} {3}" -f "ID", "DATE", "SIZE", "TAG") -ForegroundColor White
    Write-Host ("─" * 70)

    foreach ($snap in $snaps) {
        $id = Split-Path $snap -Leaf
        $datePart = $id.Substring(0,8)
        $timePart = $id.Substring(9,6)
        $formatted = "$($datePart.Substring(0,4))-$($datePart.Substring(4,2))-$($datePart.Substring(6,2)) $($timePart.Substring(0,2)):$($timePart.Substring(2,2))"
        $size = Human-Size $snap
        $tag = if ($id -match "^\d{8}-\d{6}-(.+)$") { $Matches[1] } else { "" }
        Write-Host ("{0,-28} {1,-22} {2,-10} {3}" -f $id, $formatted, $size, $tag)
    }
    Write-Host ""
}

# ─── status ──────────────────────────────────────────────────────────────────
function Do-Status {
    Require-Windows
    Load-Config

    Write-Host ""
    Write-Host "Claude Backup Status" -ForegroundColor White
    Write-Host ("─" * 32)

    $snaps = List-Snapshots
    if ($snaps.Count -gt 0) {
        $lastId   = Split-Path $snaps[0] -Leaf
        $lastSize = Human-Size $snaps[0]
        Write-Host "  Last backup:  $lastId ($lastSize)"
        Write-Host "  Total snaps:  $($snaps.Count) (max $MAX_SNAPSHOTS)"
    } else {
        Write-Host "  Last backup:  " -NoNewline
        Write-Host "none" -ForegroundColor Yellow
    }

    Write-Host "  Backup root:  $BACKUP_ROOT"
    Write-Host "  Backend:      $($script:BACKEND)"
    if ($script:BACKEND -eq "git") {
        if ($script:GIT_REMOTE) { Write-Host "  Git remote:   $($script:GIT_REMOTE)" }
        else { Write-Host "  Git remote:   " -NoNewline; Write-Host "not configured — run: claude-bak setup git" -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host "  Source sizes:"
    Write-Host "    ~\.claude\        $(Human-Size $CLAUDE_CODE_DIR)"
    Write-Host "    %APPDATA%\Claude\ $(Human-Size $CLAUDE_DESKTOP_DIR)"
    Write-Host ""
}

# ─── sync ────────────────────────────────────────────────────────────────────
function Do-Sync {
    param([string]$direction = "push")
    Require-Windows
    Load-Config

    if ($Remote) { $script:GIT_REMOTE = $Remote; $script:BACKEND = "git"; Save-Config }

    if ($script:BACKEND -ne "git" -or -not $script:GIT_REMOTE) {
        Die "Git remote not configured. Run: claude-bak setup git"
    }
    if (-not (Test-Path (Join-Path $BACKUP_ROOT ".git"))) {
        Die "Backup root is not a git repo. Run: claude-bak setup git"
    }

    switch ($direction) {
        "push" {
            Log "Syncing to $($script:GIT_REMOTE) …"
            git -C $BACKUP_ROOT add -A
            git -C $BACKUP_ROOT commit -m "sync $(Get-Date -Format 'yyyy-MM-dd HH:mm')" --quiet 2>$null
            git -C $BACKUP_ROOT push --quiet
            Ok "Pushed to $($script:GIT_REMOTE)"
        }
        "pull" {
            Log "Pulling from $($script:GIT_REMOTE) …"
            git -C $BACKUP_ROOT pull --quiet
            Ok "Pulled from $($script:GIT_REMOTE)"
        }
        default { Die "Usage: claude-bak sync push|pull [-Remote <url>]" }
    }
}

# ─── setup ───────────────────────────────────────────────────────────────────
function Do-Setup {
    param([string]$mode = "local")
    Require-Windows
    Load-Config

    switch ($mode) {
        "local" {
            if (-not (Test-Path $BACKUP_ROOT)) { New-Item -ItemType Directory -Path $BACKUP_ROOT -Force | Out-Null }
            $script:BACKEND = "local"
            Save-Config
            Ok "Local backend configured → $BACKUP_ROOT"
        }
        "git" {
            $gitPath = Get-Command git -ErrorAction SilentlyContinue
            if (-not $gitPath) { Die "git is not installed. Install Git for Windows: https://git-scm.com/download/win" }

            if (-not (Test-Path $BACKUP_ROOT)) { New-Item -ItemType Directory -Path $BACKUP_ROOT -Force | Out-Null }

            $remoteUrl = Read-Host "Enter git remote URL (e.g. git@github.com:you/claude-backup.git)"
            if (-not $remoteUrl) { Die "Remote URL cannot be empty" }

            $script:GIT_REMOTE = $remoteUrl
            $script:BACKEND = "git"

            if (-not (Test-Path (Join-Path $BACKUP_ROOT ".git"))) {
                git -C $BACKUP_ROOT init --quiet
            }

            # .gitignore
            @"
desktop\Cache\
desktop\Code Cache\
desktop\GPUCache\
code\cache\
code\telemetry\
"@ | Set-Content (Join-Path $BACKUP_ROOT ".gitignore")

            git -C $BACKUP_ROOT remote remove origin 2>$null
            git -C $BACKUP_ROOT remote add origin $remoteUrl
            Save-Config

            Ok "Git backend configured → $remoteUrl"
            Log "Running first backup …"
            Do-Backup "all"
            Log "Pushing to remote …"
            git -C $BACKUP_ROOT push -u origin HEAD --quiet 2>$null
            if ($LASTEXITCODE -eq 0) { Ok "First push complete" }
            else { Warn "Push failed — check your remote URL and credentials, then run: claude-bak sync push" }
        }
        default { Die "Usage: claude-bak setup local|git" }
    }
}

# ─── main ────────────────────────────────────────────────────────────────────
function Show-Usage {
    Write-Host @"

Usage: claude-bak <command> [options]

Commands:
  backup  [all|code|desktop] [-Tag <name>]     Create a snapshot
  restore [all|code|desktop] [snapshot-id]     Restore (default: latest)
  list                                          Show all snapshots
  status                                        Show backup status
  sync    push|pull [-Remote <url>]             Git-based sync
  setup   local|git                             Configure backend

Examples:
  claude-bak backup
  claude-bak backup code -Tag before-update
  claude-bak restore
  claude-bak restore all 20260519-143022
  claude-bak setup git
  claude-bak sync push
"@
}

switch ($Command.ToLower()) {
    ""        { Show-Usage }
    "backup"  { Do-Backup  -target $(if ($Arg1) { $Arg1 } else { "all" }) -tag $Tag }
    "restore" { Do-Restore -target $(if ($Arg1) { $Arg1 } else { "all" }) -snapArg $(if ($Arg2) { $Arg2 } else { "latest" }) }
    "list"    { Do-List }
    "status"  { Do-Status }
    "sync"    { Do-Sync    -direction $(if ($Arg1) { $Arg1 } else { "push" }) }
    "setup"   { Do-Setup   -mode $(if ($Arg1) { $Arg1 } else { "local" }) }
    "help"    { Show-Usage }
    default   { Err "Unknown command: $Command"; Show-Usage; exit 1 }
}
