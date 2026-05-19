# claude-backup

Backup, restore, and sync Claude across machines — one command.

---

## ⚠️ Read before deleting anything

Claude stores data in two places that are **not backed up automatically**:

**macOS:**
| What | Where | Lost if deleted |
|----|------|-----------------|
| Settings, skills, projects | `~/.claude/` | All installed skills, settings.json, project history |
| Cowork sessions, config | `~/Library/Application Support/Claude/` | **All Cowork conversations**, sessions, Desktop config |

**Windows:**
| What | Where | Lost if deleted |
|----|------|-----------------|
| Settings, skills, projects | `%USERPROFILE%\.claude\` | All installed skills, settings.json, project history |
| Cowork sessions, config | `%APPDATA%\Claude\` | **All Cowork conversations**, sessions, Desktop config |

**If you delete either folder without a backup — the data is gone permanently.**

### Commands that look safe but aren't

```bash
# 🔴 Deletes all Claude Code settings
rm -rf ~/.claude

# 🔴 Deletes all Cowork conversations
rm -rf ~/Library/Application\ Support/Claude

# ⚠️ Looks like a cache cleanup — but deletes everything
rm -rf ~/.claude/cache    # ✅ safe
rm -rf ~/.claude/*        # 🔴 deletes everything
```

**Before any destructive operation — always run first:**
```bash
claude-bak backup all --tag safety
```

---

## What it does

A Claude Code skill that adds the `claude-bak` command.
Backs up your entire Claude state — settings, skills, and Cowork sessions.

**Two targets:**
- **`code`** — `~/.claude/` — settings, skills, projects, sessions
- **`sessions`** — Cowork conversations and Claude Desktop config

**What's excluded** (rebuilt automatically, not worth storing):
- Cache, GPUCache, vm_bundles (12GB+ of runtime files)
- Crashpad, sentry, telemetry

---

## Install

### macOS
```bash
git clone https://github.com/azuko3/claude-backup-skill.git ~/.claude/skills/claude-backup
bash ~/.claude/skills/claude-backup/install.sh
```

Add to `~/.zshrc` if `claude-bak` is not recognized:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Windows
Open **PowerShell** and run:
```powershell
git clone https://github.com/azuko3/claude-backup-skill.git "$env:USERPROFILE\.claude\skills\claude-backup"
& "$env:USERPROFILE\.claude\skills\claude-backup\install.ps1"
```

If you get a "scripts disabled" error, run this first:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Commands

### Backup & restore
```bash
claude-bak backup                            # back up everything
claude-bak backup --tag weekly              # back up everything, with a label
claude-bak backup code --tag before-update  # code only, with a label
claude-bak backup sessions                   # Cowork sessions only

claude-bak restore                           # restore latest snapshot
claude-bak restore all 20260519-143022       # restore a specific snapshot

claude-bak list                              # all snapshots with sizes and dates
claude-bak status                            # last backup time, source sizes
```

### Explore snapshots
```bash
claude-bak tree                              # browse files and sizes
claude-bak tree latest code                  # code target only

claude-bak diff                              # what changed between the last two snapshots
claude-bak diff 20260519-115152 20260519-115823

claude-bak find settings.json               # search for a file by name
claude-bak show latest code/settings.json   # read a file from a snapshot
```

### Sync
```bash
claude-bak setup git                         # configure a git remote
claude-bak sync push                         # push to git
claude-bak sync pull                         # pull from git

claude-bak setup icloud                      # iCloud sync (macOS only)
```

---

## Restore behavior

Before every restore, a safety snapshot is created automatically and a confirmation is shown:

```
This will overwrite your current Claude state with snapshot: 20260519-115152-work
  code:     full mirror — files not in snapshot will be deleted
  sessions: overwrite only — new files added since backup will be kept
Continue? [y/N]
```

---

## Moving to a new machine

**On the old machine:**
```bash
claude-bak backup all --tag pre-migration
claude-bak setup git
claude-bak sync push
```

**On the new machine:**
```bash
git clone <remote-url> ~/backups/claude
bash ~/.claude/skills/claude-backup/install.sh
claude-bak restore all
```

---

## Backends

| Backend | Where stored | Best for |
|---------|-------------|---------|
| `local` | `~/backups/claude/` (keeps last 10) | Daily use |
| `git` | Private GitHub/GitLab repo | Sync across machines |
| `icloud` | iCloud Drive (macOS only) | Transparent sync — ⚠️ never open Claude on two machines at the same time |
