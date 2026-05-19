# claude-backup

גיבוי, שחזור וסנכרון של Claude בין מחשבים — בפקודה אחת.

---

## ⚠️ קרא לפני שאתה מוחק כלום

Claude שומר הכל בשני מקומות שאינם גיבוי אוטומטי:

**macOS:**
| מה | איפה | מה ייאבד אם תמחק |
|----|------|-------------------|
| הגדרות, skills, projects | `~/.claude/` | כל ה-skills, settings, היסטוריית projects |
| שיחות Cowork, קונפיגורציה | `~/Library/Application Support/Claude/` | **כל שיחות ה-Cowork**, sessions, הגדרות |

**Windows:**
| מה | איפה | מה ייאבד אם תמחק |
|----|------|-------------------|
| הגדרות, skills, projects | `%USERPROFILE%\.claude\` | כל ה-skills, settings, היסטוריית projects |
| שיחות Cowork, קונפיגורציה | `%APPDATA%\Claude\` | **כל שיחות ה-Cowork**, sessions, הגדרות |

**אם מחקת בלי backup — הנתונים אבדו לצמיתות.**

### פקודות מסוכנות שנראות תמימות

```bash
# 🔴 מוחק את כל הגדרות Claude Code
rm -rf ~/.claude

# 🔴 מוחק את כל שיחות Cowork
rm -rf ~/Library/Application\ Support/Claude

# ⚠️ נראה כמו ניקוי cache — אבל מוחק הכל
rm -rf ~/.claude/cache    # ✅ בטוח
rm -rf ~/.claude/*        # 🔴 מוחק הכל
```

**לפני כל פעולה הרסנית — תמיד קודם:**
```bash
claude-bak backup all --tag safety
```

---

## מה זה

Skill ל-Claude Code שמוסיף פקודת `claude-bak`.
מגבה את כל ה-state של Claude — הגדרות, skills, ושיחות Cowork.

**שני targets:**
- **`code`** — `~/.claude/` — הגדרות, skills, projects, sessions
- **`sessions`** — שיחות Cowork וקונפיגורציה של Claude Desktop

**מה לא מגובה** (נוצר מחדש אוטומטית, לא שווה לאחסן):
- Cache, GPUCache, vm_bundles (12GB+ של runtime)
- Crashpad, sentry, telemetry

---

## התקנה

### macOS
```bash
git clone https://github.com/azuko3/claude-backup-skill.git ~/.claude/skills/claude-backup
bash ~/.claude/skills/claude-backup/install.sh
```

הוסף ל-`~/.zshrc` אם `claude-bak` לא מוכר:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Windows
פתח **PowerShell** והרץ:
```powershell
git clone https://github.com/azuko3/claude-backup-skill.git "$env:USERPROFILE\.claude\skills\claude-backup"
& "$env:USERPROFILE\.claude\skills\claude-backup\install.ps1"
```

אם מופיעה שגיאה על scripts disabled:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## פקודות

### גיבוי ושחזור
```bash
claude-bak backup                        # גבה הכל
claude-bak backup code --tag before-update  # רק code, עם תג
claude-bak backup sessions               # רק שיחות Cowork

claude-bak restore                       # שחזר את האחרון
claude-bak restore all 20260519-143022   # שחזר snapshot ספציפי

claude-bak list                          # כל ה-snapshots עם גדלים ותאריכים
claude-bak status                        # מצב: מתי גיבוי אחרון, גדלים
```

### חקירת snapshot
```bash
claude-bak tree                          # עץ קבצים עם גדלים
claude-bak tree latest code              # רק code

claude-bak diff                          # מה השתנה בין שני הגיבויים האחרונים
claude-bak diff 20260519-115152 20260519-115823

claude-bak find settings.json           # חיפוש קובץ לפי שם
claude-bak show latest code/settings.json   # תוכן קובץ ספציפי
```

### סנכרון
```bash
claude-bak setup git                     # הגדרת git remote
claude-bak sync push                     # שלח לgit
claude-bak sync pull                     # קבל מgit

claude-bak setup icloud                  # סנכרון דרך iCloud (macOS)
```

---

## התנהגות restore

לפני כל restore — נוצר אוטומטית safety snapshot ומוצגת הודעה:

```
This will overwrite your current Claude state with snapshot: 20260519-115152-work
  code:     full mirror — files not in snapshot will be deleted
  sessions: overwrite only — new files added since backup will be kept
Continue? [y/N]
```

---

## מעבר למחשב חדש

**על המחשב הישן:**
```bash
claude-bak backup all --tag pre-migration
claude-bak setup git
claude-bak sync push
```

**על המחשב החדש:**
```bash
git clone <remote-url> ~/backups/claude
bash ~/.claude/skills/claude-backup/install.sh
claude-bak restore all
```

---

## Backends

| Backend | איפה שמור | מתאים ל |
|---------|-----------|---------|
| `local` | `~/backups/claude/` (10 אחרונים) | שימוש יומיומי |
| `git` | ריפו פרטי ב-GitHub/GitLab | סנכרון בין מחשבים |
| `icloud` | iCloud Drive (macOS בלבד) | סנכרון שקוף — ⚠️ לא לפתוח על שני מחשבים בו-זמנית |
