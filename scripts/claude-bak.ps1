# claude-bak.ps1 — backup, restore, and sync Claude state on Windows
# Requires: PowerShell 5.1+ (built into Windows 10/11)
#
# Usage: claude-bak <command> [options]
#   backup  [all|code|sessions] [-Tag <name>]
#   restore [all|code|sessions] [snapshot-id|latest]
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

    if ($target -eq "all" -or $target -eq "sessions") {
        Log "Backing up Claude sessions …"
        if (-not (Test-Path $CLAUDE_DESKTOP_DIR)) {
            Warn "Claude Desktop directory not found — skipping"
        } else {
            $claudeProc = Get-Process "Claude" -ErrorAction SilentlyContinue
            if ($claudeProc) { Warn "Claude Desktop is running — backup will proceed but data may be inconsistent" }
            $dest = Join-Path $snapDir "sessions"
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
    if ($target -eq "all" -or $target -eq "code") {
        Write-Host "  code:     full mirror — files not in snapshot will be deleted"
    }
    if ($target -eq "all" -or $target -eq "sessions") {
        Write-Host "  sessions: overwrite only — new files added since backup will be kept"
    }
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

    if ($target -eq "all" -or $target -eq "sessions") {
        $src = Join-Path $snapDir "sessions"
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
        } else { Warn "No sessions backup in this snapshot" }
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
# ── credentials & sensitive files ────────────────────────────────────────────
# These files may contain API keys, MCP tokens, and auth credentials.
# NEVER commit these to a public repo.
code\.claude.json
code\auth\
code\.credentials\
code\mcp-needs-auth-cache.json

# ── large runtime files ───────────────────────────────────────────────────────
sessions\Cache\
sessions\Code Cache\
sessions\GPUCache\
sessions\DawnGraphiteCache\
sessions\DawnWebGPUCache\
sessions\Crashpad\
sessions\blob_storage\
sessions\sentry\

# ── transient code files ──────────────────────────────────────────────────────
code\cache\
code\telemetry\
code\downloads\
"@ | Set-Content (Join-Path $BACKUP_ROOT ".gitignore")

            Warn "IMPORTANT: backups may contain API keys and MCP credentials."
            Warn "Make sure your git remote is a PRIVATE repo, not public."

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

# ─── tree ────────────────────────────────────────────────────────────────────
function Do-Tree {
    param([string]$snapArg = "latest", [string]$target = "all")
    $snaps = List-Snapshots
    $snapDir = if ($snapArg -eq "latest") {
        if ($snaps.Count -eq 0) { Die "No snapshots found. Run: claude-bak backup" }
        $snaps[0]
    } else {
        $p = Join-Path $BACKUP_ROOT $snapArg
        if (-not (Test-Path $p)) { Die "Snapshot '$snapArg' not found" }
        $p
    }
    $snapId = Split-Path $snapDir -Leaf
    Write-Host ""
    Write-Host "Snapshot: $snapId" -ForegroundColor White

    function Print-Tree { param([string]$dir, [string]$prefix)
        $items = Get-ChildItem $dir -ErrorAction SilentlyContinue | Sort-Object Name
        $count = $items.Count; $i = 0
        foreach ($item in $items) {
            $i++
            $connector = if ($i -eq $count) { "└── " } else { "├── " }
            $childPrefix = if ($i -eq $count) { "$prefix    " } else { "$prefix│   " }
            if ($item.PSIsContainer) {
                $sz = Human-Size $item.FullName
                Write-Host "$prefix$connector" -NoNewline
                Write-Host "$($item.Name)/" -ForegroundColor Blue -NoNewline
                Write-Host " ($sz)" -ForegroundColor DarkGray
                Print-Tree $item.FullName $childPrefix
            } else {
                $sz = if ($item.Length -gt 1MB) { "{0:N1}MB" -f ($item.Length/1MB) }
                      elseif ($item.Length -gt 1KB) { "{0:N1}KB" -f ($item.Length/1KB) }
                      else { "$($item.Length)B" }
                Write-Host "$prefix$connector$($item.Name) " -NoNewline
                Write-Host "($sz)" -ForegroundColor DarkGray
            }
        }
    }

    foreach ($t in @("code","sessions")) {
        if ($target -ne "all" -and $target -ne $t) { continue }
        $tdir = Join-Path $snapDir $t
        if (-not (Test-Path $tdir)) { continue }
        Write-Host ""
        Write-Host "$t/" -ForegroundColor Yellow -NoNewline
        Write-Host " ($(Human-Size $tdir))" -ForegroundColor DarkGray
        Print-Tree $tdir ""
    }
    Write-Host ""
}

# ─── diff ─────────────────────────────────────────────────────────────────────
function Do-Diff {
    param([string]$snapA = "", [string]$snapB = "")
    $snaps = List-Snapshots
    if (-not $snapA) {
        if ($snaps.Count -lt 2) { Die "Need at least 2 snapshots to diff" }
        $snapA = Split-Path $snaps[1] -Leaf
        $snapB = Split-Path $snaps[0] -Leaf
    } elseif (-not $snapB) {
        $snapB = Split-Path $snaps[0] -Leaf
    }

    $dirA = Join-Path $BACKUP_ROOT $snapA
    $dirB = Join-Path $BACKUP_ROOT $snapB
    if (-not (Test-Path $dirA)) { Die "Snapshot '$snapA' not found" }
    if (-not (Test-Path $dirB)) { Die "Snapshot '$snapB' not found" }

    Write-Host ""
    Write-Host "Diff: $snapA → $snapB" -ForegroundColor White
    Write-Host ("─" * 52)

    $filesA = Get-ChildItem $dirA -Recurse -File | ForEach-Object { $_.FullName.Replace("$dirA\","") } | Where-Object { $_ -ne "manifest.json" }
    $filesB = Get-ChildItem $dirB -Recurse -File | ForEach-Object { $_.FullName.Replace("$dirB\","") } | Where-Object { $_ -ne "manifest.json" }

    $added   = $filesB | Where-Object { $_ -notin $filesA }
    $removed = $filesA | Where-Object { $_ -notin $filesB }
    $common  = $filesA | Where-Object { $_ -in $filesB }

    foreach ($f in $added)   { Write-Host "+ $f" -ForegroundColor Green }
    foreach ($f in $removed) { Write-Host "- $f" -ForegroundColor Red }
    foreach ($f in $common) {
        $sA = (Get-Item (Join-Path $dirA $f) -ErrorAction SilentlyContinue).Length
        $sB = (Get-Item (Join-Path $dirB $f) -ErrorAction SilentlyContinue).Length
        if ($sA -ne $sB) { Write-Host "~ $f " -ForegroundColor Yellow -NoNewline; Write-Host "($sA → $sB bytes)" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "Summary: " -NoNewline -ForegroundColor DarkGray
    Write-Host "+$($added.Count) added  " -ForegroundColor Green -NoNewline
    Write-Host "-$($removed.Count) removed  " -ForegroundColor Red -NoNewline
    Write-Host "~$(($common | Where-Object { (Get-Item (Join-Path $dirA $_) -EA SilentlyContinue).Length -ne (Get-Item (Join-Path $dirB $_) -EA SilentlyContinue).Length }).Count) changed" -ForegroundColor Yellow
    Write-Host ""
}

# ─── show ─────────────────────────────────────────────────────────────────────
function Do-Show {
    param([string]$snapArg = "latest", [string]$filePath = "")
    if (-not $filePath) { Die "Usage: claude-bak show [snapshot-id] <file-path>`nExample: claude-bak show latest code/settings.json" }

    $snaps = List-Snapshots
    $snapDir = if ($snapArg -eq "latest") {
        if ($snaps.Count -eq 0) { Die "No snapshots found" }
        $snaps[0]
    } else {
        $p = Join-Path $BACKUP_ROOT $snapArg; if (-not (Test-Path $p)) { Die "Snapshot '$snapArg' not found" }; $p
    }

    $full = Join-Path $snapDir $filePath
    if (-not (Test-Path $full)) {
        Err "File not found: $filePath"
        Write-Host "Tip: use 'claude-bak find <pattern>' to search for files"
        exit 1
    }

    $snapId = Split-Path $snapDir -Leaf
    Write-Host ""
    Write-Host "$snapId → $filePath" -ForegroundColor DarkGray
    Write-Host ("─" * 52)
    Get-Content $full
    Write-Host ""
}

# ─── find ─────────────────────────────────────────────────────────────────────
function Do-Find {
    param([string]$pattern = "", [string]$snapArg = "latest")
    if (-not $pattern) { Die "Usage: claude-bak find <pattern> [snapshot-id]`nExample: claude-bak find settings.json" }

    $snaps = List-Snapshots
    $snapDir = if ($snapArg -eq "latest") {
        if ($snaps.Count -eq 0) { Die "No snapshots found" }
        $snaps[0]
    } else {
        $p = Join-Path $BACKUP_ROOT $snapArg; if (-not (Test-Path $p)) { Die "Snapshot '$snapArg' not found" }; $p
    }

    $snapId = Split-Path $snapDir -Leaf
    Write-Host ""
    Write-Host "Searching `"$pattern`" in snapshot: $snapId" -ForegroundColor White
    Write-Host ("─" * 52)

    $results = Get-ChildItem $snapDir -Recurse -Filter "*$pattern*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "manifest.json" }

    foreach ($r in $results) {
        $rel = $r.FullName.Replace("$snapDir\","")
        $sz = Human-Size $r.FullName
        Write-Host "  $rel " -NoNewline; Write-Host "($sz)" -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($results.Count -eq 0) { Warn "No files matching '$pattern'" }
    else { Write-Host "$($results.Count) result(s). Use: claude-bak show $snapId <path>" -ForegroundColor DarkGray }
    Write-Host ""
}

# ─── main ────────────────────────────────────────────────────────────────────
function Show-Usage {
    Write-Host @"

Usage: claude-bak <command> [options]

Backup & restore:
  backup  [all|code|sessions] [-Tag <name>]     Create a snapshot
  restore [all|code|sessions] [snapshot-id]     Restore (default: latest)
  list                                          Show all snapshots
  status                                        Show backup status
  sync    push|pull [-Remote <url>]             Git-based sync
  setup   local|git                             Configure backend

Explore:
  tree    [snapshot-id] [all|code|sessions]      Browse files + sizes
  diff    [snapshot-a] [snapshot-b]             What changed between two snapshots
  show    [snapshot-id] <file-path>             Print contents of a file
  find    <pattern> [snapshot-id]               Search files by name

Examples:
  claude-bak backup
  claude-bak backup code -Tag before-update
  claude-bak restore
  claude-bak tree
  claude-bak diff
  claude-bak find settings.json
  claude-bak show latest code/settings.json
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
    "tree"    { Do-Tree    -snapArg $(if ($Arg1) { $Arg1 } else { "latest" }) -target $(if ($Arg2) { $Arg2 } else { "all" }) }
    "diff"    { Do-Diff    -snapA $Arg1 -snapB $Arg2 }
    "show"    { Do-Show    -snapArg $(if ($Arg1) { $Arg1 } else { "latest" }) -filePath $Arg2 }
    "find"    { Do-Find    -pattern $Arg1 -snapArg $(if ($Arg2) { $Arg2 } else { "latest" }) }
    "help"    { Show-Usage }
    default   { Err "Unknown command: $Command"; Show-Usage; exit 1 }
}
