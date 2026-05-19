---
name: claude-backup
description: >
  Backup, restore, and sync Claude state across machines — covers Claude Code
  (~/.claude), Claude Desktop, and Cowork sessions
  (~/Library/Application Support/Claude). Use this skill whenever the user
  mentions backing up Claude, losing sessions, transferring to a new machine,
  syncing between computers, or setting up Claude on a fresh install.
  Also trigger when the user asks about rm -rf on Claude directories,
  recovering lost sessions, or setting up Time Machine for Claude.
compatibility:
  os: macOS, Windows
  tools: bash (macOS), PowerShell (Windows)
---

# claude-backup skill

This skill gives Claude the ability to backup, restore, and sync all Claude state using the `claude-bak` CLI.

## When to use

Trigger this skill when the user:
- Wants to back up Claude (code, sessions, or both)
- Is moving to a new machine or fresh install
- Wants to sync Claude state between computers
- Has lost sessions or wants to recover them
- Asks about `rm -rf ~/.claude` or `rm -rf ~/Library/Application Support/Claude`
- Wants to set up Time Machine, iCloud, or git sync for Claude
- Asks "how do I restore my Claude settings"

## What `claude-bak` covers

| Target | Source path | Contents |
|--------|-------------|----------|
| `code` | `~/.claude/` | settings.json, skills, projects, sessions |
| `sessions` | `~/Library/Application Support/Claude/` | Cowork sessions, IndexedDB, config, auth |
| `all` | both | default for most operations |

Excluded automatically: browser caches, GPU cache, vm_bundles, telemetry, crash reports (large, not useful to back up).

## Commands

```bash
claude-bak backup [all|code|sessions] [--tag <name>]
claude-bak restore [all|code|sessions] [snapshot-id|latest]
claude-bak list
claude-bak status
claude-bak tree [snapshot-id] [all|code|sessions]
claude-bak diff [snapshot-a] [snapshot-b]
claude-bak find <pattern> [snapshot-id]
claude-bak show [snapshot-id] <file-path>
claude-bak sync push|pull [--remote <url>]
claude-bak setup local|git|icloud
```

## How to assist the user

1. **Check if claude-bak is installed first:**
   ```bash
   which claude-bak 2>/dev/null || echo "not installed"
   ```
   If not installed, run the installer:
   ```bash
   bash ~/.claude/skills/claude-backup/install.sh
   ```

2. **For a new machine setup:**
   - On the old machine: `claude-bak backup all --tag pre-migration` then `claude-bak setup git`
   - On the new machine: clone the git repo to `~/backups/claude`, run `claude-bak restore all`

3. **For iCloud sync:** warn the user to never open Claude on two machines at the same time.

4. **Before any destructive operation** (`rm -rf`, major upgrade): run `claude-bak backup all --tag safety` first.

## Restore behavior

- `code` restore: full mirror — files not in snapshot are deleted
- `sessions` restore: overwrite only — files not in snapshot are kept
- Every restore creates an automatic safety snapshot before overwriting and asks for `y/n` confirmation

## Backends

- `local` — snapshots in `~/backups/claude/`, keeps last 10, auto-rotated (default)
- `git` — private git repo; auto-push on backup; pull on new machine
- `icloud` — symlink `~/Library/Application Support/Claude` into iCloud Drive; macOS only

## References

- Troubleshooting: `~/.claude/skills/claude-backup/references/troubleshooting.md`
- Backend details: `~/.claude/skills/claude-backup/references/backends.md`
