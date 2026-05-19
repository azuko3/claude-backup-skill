# Backends

## local (default)

**Where:** `~/backups/claude/`

**Rotation:** Keeps the 10 most recent snapshots. Oldest are deleted automatically.

**Pros:** Zero setup, works offline, fast.

**Cons:** No off-machine copy. If your drive fails, backups are lost too.

**Setup:**
```bash
claude-bak setup local
```

---

## git

**Where:** `~/backups/claude/` + a private remote repo

**How it works:** Every `backup` command commits and pushes to the remote. On a new machine, clone the repo and run `restore`.

**Pros:** Full history, works across machines, free with GitHub/GitLab private repos.

**Cons:** Requires git access; large snapshots mean large repo over time.

**Setup:**
```bash
claude-bak setup git
# prompts for: git@github.com:you/claude-backup.git
```

**Manual push/pull:**
```bash
claude-bak sync push
claude-bak sync pull
```

**New machine restore flow:**
```bash
git clone git@github.com:you/claude-backup.git ~/backups/claude
claude-bak restore all
```

**Repo size tip:** Consider adding older snapshots to `.gitignore` or using `git gc` periodically if the repo grows too large.

---

## icloud

**Where:** `~/Library/Mobile Documents/com~apple~CloudDocs/Claude/`

**How it works:** Moves `~/Library/Application Support/Claude` into iCloud Drive and leaves a symlink in its place. iCloud syncs automatically.

**Pros:** Zero-effort sync, works transparently with the app.

**Cons:** macOS only. Syncs in near-real-time — NOT a snapshot history. One bad state will sync immediately.

**Critical warning:** **Never open Claude Desktop on two machines at the same time.** The app writes to LevelDB and SQLite files that are not safe for concurrent iCloud sync. This can corrupt your data.

**Prerequisites:**
- macOS with iCloud Drive enabled
- Claude Desktop must be quit before setup

**Setup:**
```bash
claude-bak setup icloud
```

**Undo iCloud sync:**
```bash
# quit Claude Desktop first
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Claude"
TARGET="$HOME/Library/Application Support/Claude"
rm "$TARGET"                          # remove symlink
cp -r "$ICLOUD" "$TARGET"             # copy back
```

---

## Combining backends

The recommended setup for power users:
1. **icloud** for seamless real-time sync between your main machines
2. **git** for snapshot history and disaster recovery

Set up iCloud first, then periodically run `claude-bak backup --tag weekly` with a git backend for point-in-time snapshots.
