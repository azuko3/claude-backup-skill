#!/usr/bin/env bash
# claude-bak — backup, restore, and sync Claude state across machines
set -euo pipefail

# ─── constants ───────────────────────────────────────────────────────────────
CLAUDE_CODE_DIR="$HOME/.claude"
CLAUDE_DESKTOP_DIR="$HOME/Library/Application Support/Claude"
BACKUP_ROOT="$HOME/backups/claude"
CONFIG_FILE="$BACKUP_ROOT/.claude-bak.conf"
MAX_SNAPSHOTS=10

# ─── helpers ─────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_macos() {
  [[ "$(uname)" == "Darwin" ]] || die "claude-bak requires macOS (this version does not support Windows/Linux)"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true
  GIT_REMOTE="${GIT_REMOTE:-}"
  BACKEND="${BACKEND:-local}"
}

save_config() {
  mkdir -p "$BACKUP_ROOT"
  cat > "$CONFIG_FILE" <<EOF
BACKEND="${BACKEND:-local}"
GIT_REMOTE="${GIT_REMOTE:-}"
EOF
}

human_size() {
  # print size of path in human-readable form
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

count_files() {
  find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

snapshot_id() {
  date '+%Y%m%d-%H%M%S'
}

list_snapshots() {
  # returns snapshot dirs sorted newest-first
  [[ -d "$BACKUP_ROOT" ]] || return 0
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -not -name '.*' \
    | sort -r
}

check_disk_space() {
  local needed_kb="$1"
  local avail_kb
  avail_kb=$(df -k "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -n "$avail_kb" ]] && (( avail_kb < needed_kb )); then
    local needed_mb=$(( needed_kb / 1024 ))
    local avail_mb=$(( avail_kb / 1024 ))
    die "Not enough disk space: need ~${needed_mb}MB, only ${avail_mb}MB available"
  fi
}

write_manifest() {
  local snap_dir="$1"
  local tag="${2:-}"
  python3 - "$snap_dir" "$tag" <<'PYEOF'
import sys, json, os, datetime, platform, subprocess

snap_dir = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else ""

files = []
total_bytes = 0
for root, dirs, fnames in os.walk(snap_dir):
    # skip manifest itself
    dirs[:] = [d for d in dirs if d != '.git']
    for f in fnames:
        if f == 'manifest.json':
            continue
        path = os.path.join(root, f)
        try:
            size = os.path.getsize(path)
            total_bytes += size
            files.append(os.path.relpath(path, snap_dir))
        except OSError:
            pass

manifest = {
    "created": datetime.datetime.now().isoformat(),
    "macos_version": platform.mac_ver()[0],
    "tag": tag,
    "total_bytes": total_bytes,
    "total_mb": round(total_bytes / 1024 / 1024, 1),
    "file_count": len(files),
    "files": sorted(files)
}

with open(os.path.join(snap_dir, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2)

print(f"  files: {len(files)}, size: {manifest['total_mb']}MB")
PYEOF
}

rotate_snapshots() {
  local snaps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && snaps+=("$line")
  done < <(list_snapshots)
  local count=${#snaps[@]}
  if (( count > MAX_SNAPSHOTS )); then
    local to_delete=$(( count - MAX_SNAPSHOTS ))
    log "Rotating: removing $to_delete old snapshot(s)"
    for (( i = count - 1; i >= count - to_delete; i-- )); do
      rm -rf "${snaps[$i]}"
      echo "  removed: $(basename "${snaps[$i]}")"
    done
  fi
}

# ─── backup ──────────────────────────────────────────────────────────────────
do_backup() {
  require_macos
  load_config

  local target="${1:-all}"
  local tag=""
  # parse --tag <name>
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) shift; tag="${1:-}"; shift ;;
      *) warn "Unknown option: $1"; shift ;;
    esac
  done

  local id
  id=$(snapshot_id)
  [[ -n "$tag" ]] && id="${id}-${tag}"
  local snap_dir="$BACKUP_ROOT/$id"

  mkdir -p "$BACKUP_ROOT"

  # rough size estimate for disk check (code ~200MB generous)
  check_disk_space 512000  # 500 MB guard

  log "Creating snapshot: $id"

  if [[ "$target" == "all" || "$target" == "code" ]]; then
    log "Backing up Claude Code (~/.claude) …"
    local dest="$snap_dir/code"
    mkdir -p "$dest"
    rsync -a --delete \
      --exclude='cache/' \
      --exclude='telemetry/' \
      --exclude='downloads/' \
      --exclude='shell-snapshots/' \
      --exclude='ide/' \
      "$CLAUDE_CODE_DIR/" "$dest/" 2>/dev/null
    ok "Code: $(count_files "$dest") files ($(human_size "$dest"))"
  fi

  if [[ "$target" == "all" || "$target" == "desktop" ]]; then
    log "Backing up Claude Desktop …"
    if [[ ! -d "$CLAUDE_DESKTOP_DIR" ]]; then
      warn "Claude Desktop directory not found — skipping"
    else
      # warn if app seems open (check for lock files / processes)
      if pgrep -x "Claude" > /dev/null 2>&1; then
        warn "Claude Desktop appears to be running — backup will proceed but data may be inconsistent"
      fi
      local dest="$snap_dir/desktop"
      mkdir -p "$dest"
      rsync -a --delete \
        --exclude='Cache/' \
        --exclude='Code Cache/' \
        --exclude='GPUCache/' \
        --exclude='DawnGraphiteCache/' \
        --exclude='DawnWebGPUCache/' \
        --exclude='Crashpad/' \
        --exclude='blob_storage/' \
        --exclude='sentry/' \
        --exclude='vm_bundles/' \
        --exclude='claude-code-vm/' \
        --exclude='claude-code/' \
        --exclude='DIPS' \
        --exclude='DIPS-wal' \
        --exclude='SharedStorage' \
        --exclude='SharedStorage-wal' \
        --exclude='InterestGroups' \
        --exclude='InterestGroups-wal' \
        --exclude='WebStorage/' \
        --exclude='Session Storage/' \
        --exclude='Trust Tokens' \
        --exclude='Trust Tokens-journal' \
        --exclude='Shared Dictionary/' \
        --exclude='Partitions/' \
        --exclude='Network Persistent State' \
        --exclude='TransportSecurity' \
        --exclude='Cookies' \
        --exclude='Cookies-journal' \
        "$CLAUDE_DESKTOP_DIR/" "$dest/" 2>/dev/null
      ok "Desktop: $(count_files "$dest") files ($(human_size "$dest"))"
    fi
  fi

  log "Writing manifest …"
  local manifest_out
  manifest_out=$(write_manifest "$snap_dir" "$tag")
  echo "$manifest_out"

  rotate_snapshots

  if [[ "$BACKEND" == "git" && -n "$GIT_REMOTE" ]]; then
    log "Pushing to git remote …"
    git -C "$BACKUP_ROOT" add -A
    git -C "$BACKUP_ROOT" commit -m "snapshot $id" --quiet 2>/dev/null || true
    git -C "$BACKUP_ROOT" push --quiet 2>/dev/null && ok "Pushed to $GIT_REMOTE" || warn "Git push failed — run: claude-bak sync push"
  fi

  ok "Snapshot saved → $snap_dir"
  echo ""
  printf '\033[1m  ID:\033[0m %s\n' "$id"
  [[ -n "$tag" ]] && printf '\033[1m Tag:\033[0m %s\n' "$tag" || true
}

# ─── restore ─────────────────────────────────────────────────────────────────
do_restore() {
  require_macos
  load_config

  local target="${1:-all}"
  local snap_arg="${2:-latest}"

  # resolve snapshot
  local snap_dir=""
  if [[ "$snap_arg" == "latest" ]]; then
    snap_dir=$(list_snapshots | head -1)
    [[ -n "$snap_dir" ]] || die "No snapshots found. Run: claude-bak backup"
  else
    snap_dir="$BACKUP_ROOT/$snap_arg"
    [[ -d "$snap_dir" ]] || {
      err "Snapshot '$snap_arg' not found."
      echo "Available snapshots:"
      do_list
      exit 1
    }
  fi

  local snap_id
  snap_id=$(basename "$snap_dir")
  log "Restoring from snapshot: $snap_id"

  # safety auto-backup
  log "Creating safety backup of current state …"
  do_backup "$target" --tag "pre-restore" 2>/dev/null || warn "Safety backup failed — proceeding anyway"

  # confirm
  printf '\n\033[1;33mThis will overwrite your current Claude state with snapshot: %s\033[0m\n' "$snap_id"
  printf 'Continue? [y/N] '
  read -r answer
  [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { log "Aborted."; exit 0; }

  if [[ "$target" == "all" || "$target" == "code" ]]; then
    local src="$snap_dir/code"
    if [[ -d "$src" ]]; then
      log "Restoring Claude Code …"
      rsync -a --delete "$src/" "$CLAUDE_CODE_DIR/" 2>/dev/null
      ok "Code restored"
    else
      warn "No code backup in this snapshot"
    fi
  fi

  if [[ "$target" == "all" || "$target" == "desktop" ]]; then
    local src="$snap_dir/desktop"
    if [[ -d "$src" ]]; then
      if pgrep -x "Claude" > /dev/null 2>&1; then
        warn "Claude Desktop is running — quit it first for a clean restore"
        printf 'Proceed anyway? [y/N] '
        read -r answer2
        [[ "$(echo "$answer2" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { log "Aborted."; exit 0; }
      fi
      log "Restoring Claude Desktop …"
      rsync -a \
        "$src/" "$CLAUDE_DESKTOP_DIR/" 2>/dev/null
      ok "Desktop restored"
    else
      warn "No desktop backup in this snapshot"
    fi
  fi

  ok "Restore complete from: $snap_id"
}

# ─── list ─────────────────────────────────────────────────────────────────────
do_list() {
  require_macos
  load_config

  local snaps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && snaps+=("$line")
  done < <(list_snapshots)

  if [[ ${#snaps[@]} -eq 0 ]]; then
    echo "No snapshots found. Run: claude-bak backup"
    return 0
  fi

  printf '\n\033[1m%-28s %-22s %-10s %s\033[0m\n' "ID" "DATE" "SIZE" "TAG"
  printf '%s\n' "────────────────────────────────────────────────────────────────────"

  for snap in "${snaps[@]}"; do
    local id
    id=$(basename "$snap")
    local date_part="${id:0:8}"
    local time_part="${id:9:6}"
    local formatted_date="${date_part:0:4}-${date_part:4:2}-${date_part:6:2} ${time_part:0:2}:${time_part:2:2}"
    local size
    size=$(human_size "$snap")
    # extract tag: everything after second dash-group
    local tag=""
    if [[ "$id" =~ ^[0-9]{8}-[0-9]{6}-(.+)$ ]]; then
      tag="${BASH_REMATCH[1]}"
    fi
    printf '%-28s %-22s %-10s %s\n' "$id" "$formatted_date" "$size" "$tag"
  done
  echo ""
}

# ─── status ──────────────────────────────────────────────────────────────────
do_status() {
  require_macos
  load_config

  echo ""
  printf '\033[1mClaude Backup Status\033[0m\n'
  printf '%s\n' "────────────────────────────────"

  # last snapshot
  local last_snap
  last_snap=$(list_snapshots | head -1)
  if [[ -n "$last_snap" ]]; then
    local snap_count
    snap_count=$(list_snapshots | wc -l | tr -d ' ')
    local last_id
    last_id=$(basename "$last_snap")
    local last_size
    last_size=$(human_size "$last_snap")
    printf '  Last backup:  %s (%s)\n' "$last_id" "$last_size"
    printf '  Total snaps:  %s (max %s)\n' "$snap_count" "$MAX_SNAPSHOTS"
  else
    printf '  Last backup:  \033[33mnone\033[0m\n'
  fi

  printf '  Backup root:  %s\n' "${BACKUP_ROOT} $([ -d "$BACKUP_ROOT" ] || echo '(not created yet)')"
  printf '  Backend:      %s\n' "${BACKEND:-local}"

  if [[ "${BACKEND:-local}" == "git" ]]; then
    if [[ -n "${GIT_REMOTE:-}" ]]; then
      printf '  Git remote:   %s\n' "$GIT_REMOTE"
    else
      printf '  Git remote:   \033[33mnot configured\033[0m — run: claude-bak setup git\n'
    fi
  fi

  # icloud check
  if [[ -L "$CLAUDE_DESKTOP_DIR" ]]; then
    printf '  iCloud sync:  \033[32mactive\033[0m (Desktop is a symlink)\n'
  fi

  # source sizes
  printf '\n  Source sizes:\n'
  printf '    ~/.claude/                         %s\n' "$(human_size "$CLAUDE_CODE_DIR")"
  printf '    ~/Library/Application Support/Claude/  %s\n' "$(human_size "$CLAUDE_DESKTOP_DIR")"
  echo ""
}

# ─── sync ────────────────────────────────────────────────────────────────────
do_sync() {
  require_macos
  load_config

  local direction="${1:-push}"
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) shift; GIT_REMOTE="${1:-}"; BACKEND="git"; save_config; shift ;;
      *) warn "Unknown option: $1"; shift ;;
    esac
  done

  if [[ "$BACKEND" != "git" || -z "$GIT_REMOTE" ]]; then
    die "Git remote not configured. Run: claude-bak setup git"
  fi

  if [[ ! -d "$BACKUP_ROOT/.git" ]]; then
    die "Backup root is not a git repo. Run: claude-bak setup git"
  fi

  case "$direction" in
    push)
      log "Syncing to $GIT_REMOTE …"
      git -C "$BACKUP_ROOT" add -A
      git -C "$BACKUP_ROOT" commit -m "sync $(date '+%Y-%m-%d %H:%M')" --quiet 2>/dev/null || true
      git -C "$BACKUP_ROOT" push --quiet
      ok "Pushed to $GIT_REMOTE"
      ;;
    pull)
      log "Pulling from $GIT_REMOTE …"
      git -C "$BACKUP_ROOT" pull --quiet
      ok "Pulled from $GIT_REMOTE"
      ;;
    *)
      die "Usage: claude-bak sync push|pull [--remote <url>]"
      ;;
  esac
}

# ─── setup ───────────────────────────────────────────────────────────────────
do_setup() {
  require_macos
  load_config

  local mode="${1:-local}"

  case "$mode" in
    local)
      mkdir -p "$BACKUP_ROOT"
      BACKEND="local"
      save_config
      ok "Local backend configured → $BACKUP_ROOT"
      ;;

    git)
      command -v git > /dev/null || die "git is not installed"
      mkdir -p "$BACKUP_ROOT"

      printf 'Enter git remote URL (e.g. git@github.com:you/claude-backup.git): '
      read -r remote_url
      [[ -n "$remote_url" ]] || die "Remote URL cannot be empty"

      GIT_REMOTE="$remote_url"
      BACKEND="git"

      if [[ ! -d "$BACKUP_ROOT/.git" ]]; then
        git -C "$BACKUP_ROOT" init --quiet
      fi

      # create .gitignore
      cat > "$BACKUP_ROOT/.gitignore" <<'GITIGNORE'
# large electron caches — not worth storing
desktop/Cache/
desktop/Code Cache/
desktop/GPUCache/
desktop/DawnGraphiteCache/
desktop/DawnWebGPUCache/
desktop/Crashpad/
desktop/blob_storage/
desktop/sentry/
# transient code cache
code/cache/
code/telemetry/
code/downloads/
GITIGNORE

      git -C "$BACKUP_ROOT" remote remove origin 2>/dev/null || true
      git -C "$BACKUP_ROOT" remote add origin "$remote_url"

      save_config
      ok "Git backend configured → $remote_url"
      log "Running first backup …"
      do_backup all

      log "Pushing to remote …"
      git -C "$BACKUP_ROOT" push -u origin HEAD --quiet 2>/dev/null \
        && ok "First push complete" \
        || warn "Push failed — check your remote URL and credentials, then run: claude-bak sync push"
      ;;

    icloud)
      local icloud_root="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
      [[ -d "$icloud_root" ]] || die "iCloud Drive is not active. Enable it in System Settings → Apple ID → iCloud"

      # check Desktop dir is not already a symlink
      if [[ -L "$CLAUDE_DESKTOP_DIR" ]]; then
        ok "iCloud symlink already in place: $CLAUDE_DESKTOP_DIR → $(readlink "$CLAUDE_DESKTOP_DIR")"
        exit 0
      fi

      if pgrep -x "Claude" > /dev/null 2>&1; then
        die "Please quit Claude Desktop before setting up iCloud sync"
      fi

      local icloud_dest="$icloud_root/Claude"
      printf '\nThis will:\n  1. Move %s → %s\n  2. Create a symlink in its place\n\nContinue? [y/N] ' \
        "$CLAUDE_DESKTOP_DIR" "$icloud_dest"
      read -r answer
      [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]] || { log "Aborted."; exit 0; }

      mv "$CLAUDE_DESKTOP_DIR" "$icloud_dest"
      ln -s "$icloud_dest" "$CLAUDE_DESKTOP_DIR"

      # verify
      [[ -L "$CLAUDE_DESKTOP_DIR" ]] || die "Symlink creation failed"
      ok "iCloud sync active"
      warn "Do NOT open Claude Desktop on two machines simultaneously — data corruption risk"
      ;;

    *)
      die "Usage: claude-bak setup local|git|icloud"
      ;;
  esac
}

# ─── tree ────────────────────────────────────────────────────────────────────
do_tree() {
  local snap_arg="${1:-latest}"
  local target="${2:-all}"

  local snap_dir
  if [[ "$snap_arg" == "latest" ]]; then
    snap_dir=$(list_snapshots | head -1)
    [[ -n "$snap_dir" ]] || die "No snapshots found. Run: claude-bak backup"
  else
    snap_dir="$BACKUP_ROOT/$snap_arg"
    [[ -d "$snap_dir" ]] || die "Snapshot '$snap_arg' not found"
  fi

  local snap_id
  snap_id=$(basename "$snap_dir")
  echo ""
  printf '\033[1mSnapshot: %s\033[0m\n' "$snap_id"

  _print_tree() {
    local dir="$1"
    local prefix="$2"
    local entries=()
    while IFS= read -r entry; do
      [[ -n "$entry" ]] && entries+=("$entry")
    done < <(ls -1 "$dir" 2>/dev/null)
    local count=${#entries[@]}
    local i=0
    for entry in ${entries[@]+"${entries[@]}"}; do
      i=$(( i + 1 ))
      local path="$dir/$entry"
      local connector="├── "
      local child_prefix="$prefix│   "
      if [[ $i -eq $count ]]; then
        connector="└── "
        child_prefix="$prefix    "
      fi
      if [[ -d "$path" ]]; then
        local size
        size=$(human_size "$path")
        printf '%s%s\033[1;34m%s/\033[0m \033[2m(%s)\033[0m\n' "$prefix" "$connector" "$entry" "$size"
        _print_tree "$path" "$child_prefix"
      else
        local fsize
        fsize=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        printf '%s%s%s \033[2m(%s)\033[0m\n' "$prefix" "$connector" "$entry" "$fsize"
      fi
    done
  }

  for t in code desktop; do
    [[ "$target" != "all" && "$target" != "$t" ]] && continue
    local tdir="$snap_dir/$t"
    [[ -d "$tdir" ]] || continue
    echo ""
    printf '\033[1;33m%s/\033[0m \033[2m(%s)\033[0m\n' "$t" "$(human_size "$tdir")"
    _print_tree "$tdir" ""
  done
  echo ""
}

# ─── diff ─────────────────────────────────────────────────────────────────────
do_diff() {
  local snap_a="${1:-}"
  local snap_b="${2:-}"

  # default: compare last two snapshots
  local snaps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && snaps+=("$line")
  done < <(list_snapshots)

  if [[ -z "$snap_a" ]]; then
    [[ ${#snaps[@]} -ge 2 ]] || die "Need at least 2 snapshots to diff. Run: claude-bak backup"
    snap_a=$(basename "${snaps[1]}")
    snap_b=$(basename "${snaps[0]}")
  elif [[ -z "$snap_b" ]]; then
    snap_b=$(basename "${snaps[0]}")
  fi

  local dir_a="$BACKUP_ROOT/$snap_a"
  local dir_b="$BACKUP_ROOT/$snap_b"
  [[ -d "$dir_a" ]] || die "Snapshot '$snap_a' not found"
  [[ -d "$dir_b" ]] || die "Snapshot '$snap_b' not found"

  echo ""
  printf '\033[1mDiff: %s → %s\033[0m\n' "$snap_a" "$snap_b"
  printf '%s\n' "────────────────────────────────────────────────────"

  local added=0 removed=0 changed=0

  # files in B not in A = added
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -f "$dir_a/$f" ]]; then
      printf '\033[1;32m+ %s\033[0m\n' "$f"
      added=$(( added + 1 ))
    fi
  done < <(find "$dir_b" -type f | sed "s|$dir_b/||" | sort)

  # files in A not in B = removed
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -f "$dir_b/$f" ]]; then
      printf '\033[1;31m- %s\033[0m\n' "$f"
      removed=$(( removed + 1 ))
    fi
  done < <(find "$dir_a" -type f | sed "s|$dir_a/||" | sort)

  # files in both but different size = changed
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -f "$dir_b/$f" ]]; then
      local size_a size_b
      size_a=$(stat -f%z "$dir_a/$f" 2>/dev/null || echo 0)
      size_b=$(stat -f%z "$dir_b/$f" 2>/dev/null || echo 0)
      if [[ "$size_a" != "$size_b" ]]; then
        printf '\033[1;33m~ %s\033[0m \033[2m(%s → %s bytes)\033[0m\n' "$f" "$size_a" "$size_b"
        changed=$(( changed + 1 ))
      fi
    fi
  done < <(find "$dir_a" -type f | sed "s|$dir_a/||" | sort)

  echo ""
  printf '\033[2mSummary: \033[1;32m+%d added\033[0m  \033[1;31m-%d removed\033[0m  \033[1;33m~%d changed\033[0m\n' \
    "$added" "$removed" "$changed"
  echo ""
}

# ─── show ─────────────────────────────────────────────────────────────────────
do_show() {
  local snap_arg="${1:-latest}"
  local file_path="${2:-}"

  [[ -n "$file_path" ]] || die "Usage: claude-bak show [snapshot-id] <file-path>\nExample: claude-bak show latest code/settings.json"

  local snap_dir
  if [[ "$snap_arg" == "latest" ]]; then
    snap_dir=$(list_snapshots | head -1)
    [[ -n "$snap_dir" ]] || die "No snapshots found. Run: claude-bak backup"
  else
    snap_dir="$BACKUP_ROOT/$snap_arg"
    [[ -d "$snap_dir" ]] || die "Snapshot '$snap_arg' not found"
  fi

  local full_path="$snap_dir/$file_path"
  [[ -f "$full_path" ]] || {
    err "File not found: $file_path"
    echo "Tip: use 'claude-bak find <pattern>' to search for files"
    exit 1
  }

  local snap_id
  snap_id=$(basename "$snap_dir")
  echo ""
  printf '\033[2m%s → %s\033[0m\n' "$snap_id" "$file_path"
  printf '%s\n' "────────────────────────────────────────────────────"
  cat "$full_path"
  echo ""
}

# ─── find ─────────────────────────────────────────────────────────────────────
do_find() {
  local pattern="${1:-}"
  local snap_arg="${2:-latest}"

  [[ -n "$pattern" ]] || die "Usage: claude-bak find <pattern> [snapshot-id]\nExample: claude-bak find settings.json"

  local snap_dir
  if [[ "$snap_arg" == "latest" ]]; then
    snap_dir=$(list_snapshots | head -1)
    [[ -n "$snap_dir" ]] || die "No snapshots found. Run: claude-bak backup"
  else
    snap_dir="$BACKUP_ROOT/$snap_arg"
    [[ -d "$snap_dir" ]] || die "Snapshot '$snap_arg' not found"
  fi

  local snap_id
  snap_id=$(basename "$snap_dir")
  echo ""
  printf '\033[1mSearching "%s" in snapshot: %s\033[0m\n' "$pattern" "$snap_id"
  printf '%s\n' "────────────────────────────────────────────────────"

  local results=0
  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    local rel
    rel=$(echo "$match" | sed "s|$snap_dir/||")
    local fsize
    fsize=$(du -sh "$match" 2>/dev/null | awk '{print $1}')
    printf '  %s \033[2m(%s)\033[0m\n' "$rel" "$fsize"
    results=$(( results + 1 ))
  done < <(find "$snap_dir" -name "*$pattern*" -not -name "manifest.json" 2>/dev/null | sort)

  echo ""
  if [[ $results -eq 0 ]]; then
    warn "No files matching '$pattern'"
  else
    printf '\033[2m%d result(s). Use: claude-bak show %s <path>\033[0m\n' "$results" "$snap_id"
  fi
  echo ""
}

# ─── main ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: claude-bak <command> [options]

Backup & restore:
  backup  [all|code|desktop] [--tag <name>]          Create a snapshot
  restore [all|code|desktop] [snapshot-id|latest]    Restore a snapshot
  list                                                Show all snapshots
  status                                              Show backup status
  sync    push|pull [--remote <url>]                  Git-based sync
  setup   local|git|icloud                            Configure backend

Explore:
  tree    [snapshot-id] [all|code|desktop]            Browse files + sizes
  diff    [snapshot-a] [snapshot-b]                   What changed between two snapshots
  show    [snapshot-id] <file-path>                   Print contents of a file
  find    <pattern> [snapshot-id]                     Search files by name

Examples:
  claude-bak backup                            # backup everything
  claude-bak backup code --tag before-update
  claude-bak restore                           # restore latest
  claude-bak tree                              # browse latest snapshot
  claude-bak diff                              # compare last two snapshots
  claude-bak find settings.json               # find a file
  claude-bak show latest code/settings.json   # read a file
USAGE
}

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 0; }
shift

case "$cmd" in
  backup)  do_backup  "$@" ;;
  restore) do_restore "$@" ;;
  list)    do_list    "$@" ;;
  status)  do_status  "$@" ;;
  sync)    do_sync    "$@" ;;
  setup)   do_setup   "$@" ;;
  tree)    do_tree    "$@" ;;
  diff)    do_diff    "$@" ;;
  show)    do_show    "$@" ;;
  find)    do_find    "$@" ;;
  help|--help|-h) usage ;;
  *) err "Unknown command: $cmd"; usage; exit 1 ;;
esac
