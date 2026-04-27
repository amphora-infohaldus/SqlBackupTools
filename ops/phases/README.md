---
audience: internal
---

# Phases

Execute in order. Each phase's folder has a `README.md` with specifics.

| # | Folder | One-line purpose |
|---|---|---|
| 01 | `01-reserv-setup/` | Stand up RESERV-2025: SMB share (optional if using RichCopy only), 2nd SQL instance, cert restore, claude login |
| 02 | `02-ola-install/` | Download + customize + install Ola Hallengren's `MaintenanceSolution.sql` on each primary |
| 03 | `03-preflight/` | Flip SIMPLE → FULL recovery on all user DBs (except the exclusion list) |
| 04 | `04-wire-jobs/` | Create/update SQL Agent jobs for FULL, DIFF, LOG, MONTHLY, YEARLY + amphora_logs-specific local jobs |
| 05 | `05-richcopy/` | Configure RichCopy360 RTA jobs that move backups from primary `ship\` folders to RESERV's `C:\SqlBackup\` |
| 06 | `06-cutover/` | Manual kickoff of initial FULL on each primary, verify, enable the LOG job once all FULLs succeed |

After Phase 6, SqlBackupTools runs as a continuous restore daemon on RESERV against `C:\SqlBackup\<server>\...` — that's a separate setup documented under `ops/monitoring/` (future).
