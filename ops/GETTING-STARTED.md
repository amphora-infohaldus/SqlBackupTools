# Getting started — what to do, in order

This is the step-by-step checklist for taking the DR automation from "scaffolding committed" to "production continuous log shipping from primaries to RESERV". Follow top to bottom.

If anything in this document doesn't match reality any more, update this document as part of the fix — it's the operator's source of truth.

---

## Today (one-time bootstrap, ~30 min total)

### On YOUR workstation

- [ ] `git clone` or `git pull` the repo at `C:\Sources\SqlBackupTools`.
- [ ] Install `sops.exe` and `age.exe` (standalone Windows binaries, put on PATH).

### On EACH of the three servers (SQL-2022, PREMIUM-2022, RESERV-2025)

Do this interactively via RDP as an account with local admin rights.

- [ ] `git clone https://github.com/amphora-infohaldus/SqlBackupTools.git C:\Sources\SqlBackupTools`
- [ ] Install `sops.exe` + `age.exe` (drop in `C:\tools\` or add to PATH).
- [ ] Generate age keypair:
  ```powershell
  mkdir "$env:USERPROFILE\.config\sops\age" -Force
  age-keygen -o "$env:USERPROFILE\.config\sops\age\keys.txt"
  ```
- [ ] Print the **public** key (everything except the private line; also at the top of the keys.txt as `# public key: ...`):
  ```powershell
  Get-Content "$env:USERPROFILE\.config\sops\age\keys.txt" | Select-String 'public key'
  ```
- [ ] Set environment variable so SOPS finds the key on future sessions:
  ```powershell
  [System.Environment]::SetEnvironmentVariable('SOPS_AGE_KEY_FILE',
      "$env:USERPROFILE\.config\sops\age\keys.txt", 'User')
  ```
- [ ] Send the three public keys (one per server) to yourself / paste them into a scratch file.

### Back on your workstation

- [ ] Paste the three public keys into `.sops.yaml` (repo root, not `ops/`) — uncomment and fill in the `# - age1...` lines for each server. SOPS's config lookup walks up from the current working directory, so the file must be at or above where you invoke `sops`.
- [ ] Copy `ops/config/secrets.enc.yaml.example` to `ops/config/secrets.enc.yaml`. Fill in actual values for:
  - `claude_password` (current `claude` login password — rotate from the placeholder)
  - `sqlbackupcert_export_password` (the password used when exporting the cert — needed later for rotations)
- [ ] Encrypt the file: `sops --encrypt --in-place ops/config/secrets.enc.yaml`.
- [ ] Verify: `sops -d ops/config/secrets.enc.yaml` reads back. Delete any plain-text intermediate.
- [ ] Commit `.sops.yaml` (with real keys) + `secrets.enc.yaml` (encrypted). Push.
- [ ] On each server: `git pull`. Confirm `sops -d ops/config/secrets.enc.yaml` works on all three.

After this block, bootstrap is done. Repo pulls give each server what it needs; secrets flow via SOPS.

---

## This week (before PREMIUM-2022's in-flight FULL finishes)

The PREMIUM-2022 initial FULL kicked off against `\\10.0.0.47\SqlBackup\` (SMB direct push) and is progressing. It will keep running and land ~25 files on the RESERV share. Let it finish or cancel — either is fine, this work supersedes it.

### When you're ready to migrate to the new (RichCopy-based) pipeline

Pick a quiet time. One primary at a time (PREMIUM-2022 first so SQL-2022 keeps serving its bigger load).

On **PREMIUM-2022** (elevated PowerShell, as sysadmin-equivalent):

- [ ] `git pull` in `C:\Sources\SqlBackupTools`.
- [ ] **Phase 2 — Install Ola Hallengren** (if not already installed):
  ```powershell
  cd C:\Sources\SqlBackupTools
  .\ops\phases\02-ola-install\install-ola.ps1
  ```
  Verify with the SQL in `ops/phases/02-ola-install/README.md`.
- [ ] **Phase 3 — SIMPLE->FULL converter** (skip DBs already in FULL):
  ```powershell
  .\ops\run.ps1 phases\03-preflight\simple-to-full.sql
  ```
- [ ] **Phase 4 — Wire jobs** (creates main + amphora_logs jobs):
  ```powershell
  .\ops\run.ps1 phases\04-wire-jobs\main-jobs.sql
  .\ops\run.ps1 phases\04-wire-jobs\amphora-logs-local-jobs.sql
  ```
- [ ] **Phase 5 — RichCopy RTA job** for the new ship folder:
  - Open RichCopy360 GUI on PREMIUM-2022.
  - Add source `D:\SqlBackup\ship\`, destination `C:\SqlBackup\` on RESERV-2025, RTA mode, preserve structure, no-delete-on-source-removal.
  - See `ops/phases/05-richcopy/README.md` for full parameter list.
- [ ] **Phase 6 — Cutover** (kick off fresh initial FULL into the new pipeline):
  ```powershell
  .\ops\run.ps1 phases\06-cutover\kickoff-initial-full.sql
  ```
  Monitor via `SELECT TOP 20 ... FROM master.dbo.CommandLog ORDER BY ID DESC;`. Expect ~1-2 hours total.
- [ ] Once FULL job completes with zero errors AND files confirmed on RESERV at `C:\SqlBackup\PREMIUM-2022\<db>\FULL\*.bak`, **seed RESERV** (documented in `ops/phases/06-cutover/README.md` — requires SqlBackupTools invocation with `--noRecovery`).
- [ ] Enable LOG job:
  ```powershell
  .\ops\run.ps1 phases\06-cutover\enable-log-job.sql
  ```
- [ ] Disable the old `MaintenancePlan.FULL backup` job on PREMIUM-2022.
- [ ] Retire the old RichCopy job that was shipping flat `D:\SqlBackup\DAILY\` to RESERV (once 30 days pass or you manually delete the old archive).

Repeat Phase 2-6 on **SQL-2022**, plus identify and disable the external orchestrator that was writing to `W:\DAILY\`.

---

## After 1 week of running at 30-min LOG cadence

Once confident the pipeline holds up:

- [ ] Measure actual RichCopy lag + SqlBackupTools apply time per LOG.
- [ ] If comfortably under target, reduce `LogIntervalMinutes` in `ops/config/shared.ps1`:
  - 30 -> 15 -> 5 -> 1. Commit, pull on each primary, re-run `phases\04-wire-jobs\main-jobs.sql`.
- [ ] Document steady-state RPO in `ops/monitoring/README.md`.

---

## When a new DB collision appears

Right now only `amphora_logs` collides between SQL-2022 and PREMIUM-2022, and it's handled by exclusion. If you ever find a second collision:

- If the DB is losable: add to exclusion list in `ops/config/shared.ps1` and re-run phase 4.
- If the DB is critical + small: rename at source (simpler than adding a second instance).
- If the DB is critical + big + can't be renamed: that's when you install the `\PREMIUM` named instance on RESERV — see `ops/phases/01-reserv-setup/README.md`.

---

## Maintenance

### Rotating `claude` password

```
sops ops/config/secrets.enc.yaml    # edit in editor, re-encrypts on save
git commit -am "rotate claude password"
git push
```
On each server: `git pull`. Re-run `ops/admin/create-claude-readonly.sql` via `ops/run.ps1 admin\create-claude-readonly.sql` (needs to be adapted to use sqlcmd var instead of the hardcoded password — future work).

### Rotating LOG cadence

Edit `LogIntervalMinutes` in `ops/config/shared.ps1`. Commit+push. On each primary: `git pull`, `ops/run.ps1 phases\04-wire-jobs\main-jobs.sql`. Schedule updates, LOG keeps running on the new interval.

### Adding a DB exclusion

Edit `ExcludeListShip` (and `ExcludeListLocal` if needed) in `ops/config/shared.ps1`. Commit+push+pull+re-run as above.

---

## What's intentionally not done yet

- `\PREMIUM` named instance on RESERV (only needed if a second name collision appears)
- `Ülemus`-shared-credential service-account refactor (deferred per option B — less urgent now that RichCopy owns cross-machine transport)
- Empty `amphora_logs` placeholder + Alloy forwarding job on RESERV (see `memory/project_amphora_logs_placeholder.md`)
- Monitoring dashboards / alerting queries (`ops/monitoring/`)
- Failback runbook after primary rebuild
- Automated cert-backup-to-offline-vault script

Each of those is its own follow-up.
