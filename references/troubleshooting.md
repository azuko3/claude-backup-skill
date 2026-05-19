# Troubleshooting

## `claude-bak: command not found`

`~/.local/bin` is not in your PATH. Add to `~/.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```
Then: `source ~/.zshrc`

## Backup is very large

The backup excludes caches but still includes IndexedDB (Cowork sessions) and LocalStorage, which can be 100–500MB. This is expected.

To see what's taking space in a snapshot:
```bash
du -sh ~/backups/claude/<snapshot-id>/desktop/*/
```

## `rsync: [sender] change_dir "/Library/Application Support/Claude" failed`

Claude Desktop directory not found. Possible causes:
- Claude Desktop is not installed
- Path is different on your machine — check with: `ls ~/Library/Application\ Support/Claude/`

## Git push fails

Check that:
1. The remote URL is correct: `git -C ~/backups/claude remote -v`
2. You have push access (SSH key or HTTPS credentials configured)
3. The repo exists on the remote (create it manually if needed — make it private)

Then retry: `claude-bak sync push`

## iCloud: Claude won't open after setup

The symlink may have broken. Check:
```bash
ls -la ~/Library/Application\ Support/Claude
```
If the target doesn't exist: iCloud may not have synced yet. Wait a few minutes and check again.

## Restore didn't bring back my Cowork sessions

Cowork sessions are in `IndexedDB/https_claude.ai_0.indexeddb.leveldb/`. After restore, quit and relaunch Claude Desktop. If sessions still don't appear, the LevelDB files may need a moment to be recognized — try closing and reopening the app.

## `Not enough disk space` error

Free up space or change the backup root:
```bash
# check usage
du -sh ~/backups/claude/
# list oldest snapshots
claude-bak list
# remove a specific one manually
rm -rf ~/backups/claude/<snapshot-id>
```

## macOS permission error on ~/Library

If you get a permissions error reading `~/Library/Application Support/Claude`, grant Full Disk Access to Terminal (or iTerm2) in:
**System Settings → Privacy & Security → Full Disk Access**
