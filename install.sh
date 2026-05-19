#!/usr/bin/env bash
# install.sh — one-time setup for claude-bak
#
# What this script does (nothing hidden):
#   1. Copies scripts/claude-bak.sh to ~/.local/bin/claude-bak
#   2. chmod +x on that file
#   3. Checks if ~/.local/bin is in your PATH (prints a warning if not)
#   4. Optionally adds one cron job: claude-bak backup all --tag daily at 09:00
#   5. Runs: claude-bak status (read-only)
#
# What it does NOT do:
#   - Does not modify ~/.claude or any Claude files
#   - Does not make network requests
#   - Does not read your API keys or credentials
#   - Does not run any backup automatically
#
# To review before running:
#   cat install.sh
#   cat scripts/claude-bak.sh
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$SKILL_DIR/scripts/claude-bak.sh"
BIN_DIR="$HOME/.local/bin"
BIN_TARGET="$BIN_DIR/claude-bak"

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

if $DRY_RUN; then
  printf '\033[1m[dry-run] What install.sh would do:\033[0m\n'
  printf '  mkdir -p %s\n' "$BIN_DIR"
  printf '  cp %s %s\n' "$SCRIPT_SRC" "$BIN_TARGET"
  printf '  chmod +x %s\n' "$BIN_TARGET"
  printf '  (optionally) add cron: 0 9 * * * %s backup all --tag daily\n' "$BIN_TARGET"
  printf '\nNothing was changed. Run without --dry-run to install.\n'
  exit 0
fi

printf '\033[1mInstalling claude-bak …\033[0m\n'

# ── os check ────────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  printf '\033[1;31m✗\033[0m claude-bak requires macOS (this version does not support Windows/Linux)\n'
  exit 1
fi

# ── copy script ─────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
cp "$SCRIPT_SRC" "$BIN_TARGET"
chmod +x "$BIN_TARGET"
printf '\033[1;32m✓\033[0m Installed → %s\n' "$BIN_TARGET"

# ── PATH check ───────────────────────────────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  printf '\033[1;33m⚠\033[0m  %s is not in your PATH.\n' "$BIN_DIR"
  printf '   Add this to your ~/.zshrc or ~/.bashrc:\n'
  printf '   \033[1mexport PATH="$HOME/.local/bin:$PATH"\033[0m\n\n'
fi

# ── optional cron job ────────────────────────────────────────────────────────
printf '\nSet up a daily automatic backup? [y/N] '
read -r answer
if [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
  if crontab -l 2>/dev/null | grep -q "claude-bak backup"; then
    printf '\033[1;33m⚠\033[0m  Cron job already exists — skipping\n'
  else
    (crontab -l 2>/dev/null; echo "0 9 * * * $BIN_TARGET backup all --tag daily >> $HOME/.local/share/claude-bak.log 2>&1") | crontab -
    printf '\033[1;32m✓\033[0m Daily backup scheduled at 09:00\n'
    printf '   Log: %s\n' "$HOME/.local/share/claude-bak.log"
  fi
else
  printf '  Skipped. You can add it later with: crontab -e\n'
fi

# ── initial status ───────────────────────────────────────────────────────────
printf '\n'
"$BIN_TARGET" status 2>/dev/null || true

printf '\n\033[1mDone!\033[0m Run \033[1mclaude-bak backup\033[0m to create your first snapshot.\n'
