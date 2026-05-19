# claude-backup

Backup, restore, and sync Claude state across machines.

---

## ⚠️ קרא לפני שאתה מוחק כלום

Claude שומר הכל בשני מקומות שאינם גיבוי אוטומטי:

| מה | איפה | מה ייאבד אם תמחק |
|----|------|-------------------|
| הגדרות, skills, projects | `~/.claude/` | כל ה-skills שהתקנת, settings.json, היסטוריית projects |
| Cowork sessions, קונפיגורציה | `~/Library/Application Support/Claude/` | **כל שיחות ה-Cowork**, sessions, הגדרות Desktop |

**אם מחקת את אחד מהתיקיות האלה ואין לך backup — הנתונים אבדו לצמיתות.**

### פקודות שמחקות ואי-אפשר לשחזר בלי backup

```bash
# 🔴 מסוכן — מוחק את כל הגדרות Claude Code
rm -rf ~/.claude

# 🔴 מסוכן — מוחק את כל שיחות Cowork ואת Desktop
rm -rf ~/Library/Application\ Support/Claude

# 🔴 מסוכן — ניקוי "cache" שיכול לקחת גם sessions
rm -rf ~/.claude/cache    # זה בטוח
rm -rf ~/.claude/*        # זה מוחק הכל, לא רק cache
```

### לפני כל פעולה הרסנית — תמיד קודם

```bash
claude-bak backup all --tag safety
```

---

## מה זה claude-backup

Skill ל-Claude Code שמוסיף פקודת `claude-bak` — backup ושחזור של כל ה-state של Claude בלחיצה אחת.

**מה מגובה:**
- **code** — `~/.claude/` כולל settings, skills, projects, sessions
- **desktop** — `~/Library/Application Support/Claude/` כולל Cowork sessions, IndexedDB, קונפיגורציה

**מה מוחרג** (לא שווה לגבות — נוצר מחדש אוטומטית):
- `Cache/`, `Code Cache/`, `GPUCache/`, `vm_bundles/` (12GB+ של runtime files)
- `blob_storage/`, `Crashpad/`, `sentry/`
- `~/.claude/cache/`, `~/.claude/telemetry/`

---

## התקנה

```bash
git clone https://github.com/azuko3/claude-backup-skill.git ~/.claude/skills/claude-backup
bash ~/.claude/skills/claude-backup/install.sh
```

ואז ודא ש-`~/.local/bin` נמצא ב-PATH שלך (add to `~/.zshrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

---

## שימוש

```bash
claude-bak backup              # גבה הכל
claude-bak backup --tag weekly # עם תג לזיהוי
claude-bak list                # כל ה-snapshots
claude-bak restore             # שחזר את האחרון (עם y/n confirm)
claude-bak status              # מתי גיבוי אחרון, מה הגודל
```

### כל הפקודות

| פקודה | תיאור |
|-------|--------|
| `backup [all\|code\|desktop] [--tag name]` | יצירת snapshot |
| `restore [all\|code\|desktop] [snapshot-id\|latest]` | שחזור |
| `list` | כל ה-snapshots עם גדלים ותאריכים |
| `status` | מצב: מתי גיבוי אחרון, backend, גדלי sources |
| `sync push\|pull [--remote <url>]` | סנכרון דרך git |
| `setup local\|git\|icloud` | הגדרת backend |

---

## Backends

### local (ברירת מחדל)
Snapshots ב-`~/backups/claude/`. שומר 10 אחרונים, מוחק ישנים אוטומטית.

### git
Push לריפו פרטי (GitHub/GitLab) — מאפשר סנכרון בין מחשבים.

```bash
claude-bak setup git
# מזין Remote URL
claude-bak sync push   # שלח
claude-bak sync pull   # קבל
```

### icloud
Symlink של `~/Library/Application Support/Claude` לתוך iCloud Drive.

```bash
claude-bak setup icloud
```

> **אזהרה:** לא לפתוח Claude Desktop על שני מחשבים בו-זמנית עם iCloud — הנתונים יתקלקלו.

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

## אבטחת ה-restore

כל `restore` יוצר אוטומטית snapshot של המצב הנוכחי לפני שמשחזר, ושואל `y/n` לאישור. תמיד אפשר לחזור אחורה.
