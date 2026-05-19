# claude-backup

Backup, restore, and sync Claude state across machines.

Covers:
- **Claude Code** — `~/.claude/` (settings, skills, projects, sessions)
- **Claude Desktop** — `~/Library/Application Support/Claude/` (Cowork sessions, IndexedDB, config)

## Install

```bash
bash ~/.claude/skills/claude-backup/install.sh
```

This installs `claude-bak` to `~/.local/bin/`. Make sure that's in your `$PATH`.

## Quick start

```bash
claude-bak backup              # backup everything → ~/backups/claude/
claude-bak list                # show all snapshots
claude-bak restore             # restore latest snapshot
claude-bak status              # show last backup, size, backend
```

## Commands

| Command | Description |
|---------|-------------|
| `backup [all\|code\|desktop] [--tag name]` | Create a snapshot |
| `restore [all\|code\|desktop] [id\|latest]` | Restore a snapshot |
| `list` | Show all snapshots with sizes and tags |
| `status` | Show status: last backup, backend, source sizes |
| `sync push\|pull [--remote <url>]` | Git sync |
| `setup local\|git\|icloud` | Configure backend |

## Backends

### local (default)
Snapshots saved to `~/backups/claude/`. Keeps the 10 most recent, auto-rotates older ones.

### git
Push snapshots to a private git repo (GitHub, GitLab, etc.) for cross-machine sync.

```bash
claude-bak setup git
# enter your remote URL when prompted
```

### icloud
Symlinks `~/Library/Application Support/Claude` into iCloud Drive for automatic sync.

```bash
claude-bak setup icloud
```

**Warning:** Never open Claude Desktop on two machines simultaneously with iCloud sync enabled.

## Migrating to a new machine

On the old machine:
```bash
claude-bak backup all --tag pre-migration
claude-bak setup git    # if not already set up
claude-bak sync push
```

On the new machine:
```bash
git clone <your-remote> ~/backups/claude
bash ~/.claude/skills/claude-backup/install.sh
claude-bak restore all
```

## What's excluded

The backup skips large cache directories that are rebuilt automatically:
- `Cache/`, `Code Cache/`, `GPUCache/`, `DawnGraphiteCache/`, `DawnWebGPUCache/`
- `blob_storage/`, `Crashpad/`, `sentry/`
- `~/.claude/cache/`, `~/.claude/telemetry/`, `~/.claude/downloads/`

## Restore safety

Every `restore` command automatically creates a `pre-restore` snapshot of your current state before overwriting anything, so you can always roll back.
