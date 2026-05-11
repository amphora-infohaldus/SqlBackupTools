---
audience: internal
---

# SQL DR incident response — what to do when things go wrong

**Audience.** Anyone who gets the daily `DR digest` email, or whoever's on
call when Ingmar isn't reachable. No deep SQL Server knowledge required —
expects you to open SSMS, run PowerShell, and SSH.

**When to use this.** The morning digest shows AMBER or RED, or someone
reports a broken report / bot and a database issue is suspected.

**What this is NOT.** An automatic failover guide. Our setup is
**one-way DR** (manual cutover), not HA (high availability). No system
fails over by itself.

---

## 1. Every morning — the digest email

Around **08:00** every day, an email arrives at `ingmar@interinx.com`
with subject `DR digest [STATUS] - RESERV-2025 - <date>`. Sender:
`sqlbackup-dr@amphora.ee`.

| Status | Meaning | Action |
|---|---|---|
| **GREEN** | All clear. RESERV gets LOG copies from both primaries on time, the restore cycle runs without errors, disk has plenty of room. | Nothing. |
| **AMBER** | 1–5 databases haven't had a restore in >60 min, or another minor issue. | Go to **section 2** — find out what's lagging. |
| **RED** | The restore-cycle task ended with an error, or more than 5 databases are stale. | **Section 2** then **section 3** — start diagnosing. |

If the digest **doesn't arrive at all** (check spam too) — that's its own
issue, see **section 6**.

---

## 2. First response — see what's actually wrong

Before doing anything else, when the digest is amber or red:

### 2.1 Read the digest in full

The email has four sections:

- **Restore-cycle task** — is the Windows Task Scheduler task running
  successfully (Last result must be `0`)? If not, go to **3.1**.
- **Database inventory** — should be roughly **152 databases**, all
  `RESTORING`. If any are `ONLINE` (excluding `master`, `model`, `msdb`,
  `tempdb`), someone has manually recovered something.
- **RPO outliers** — databases whose last LOG apply was over 60 minutes
  ago. Note **which** ones and **how long** they're lagging.
- **Disk** — RESERV's free space. `C:` should be at least **15% free**
  (~2.5 TB); `H:` (HyperV disk) is a separate concern.

### 2.2 SSH into RESERV

```powershell
ssh -i $env:USERPROFILE\.ssh\claude_ai_ed25519 svc_claude_ssh@10.0.0.47
```

(The `svc_claude_ssh` account is the automation account; the key lives
in Ingmar's profile. If the key is missing or you're not Ingmar, see
`memory/project_amphora_ssh_sops_access.md` or ask Ingmar.)

Successful connection drops you at a `cmd.exe` prompt on RESERV-2025.

### 2.3 Quick state check

On RESERV (via SSH):

```cmd
sqlcmd -S . -E -W -Q "SET NOCOUNT ON; SELECT COUNT(*) AS total, SUM(CASE WHEN state_desc='RESTORING' THEN 1 ELSE 0 END) AS restoring FROM sys.databases WHERE database_id > 4;"
```

Should return something like `total=152, restoring=152`. If
`restoring < total`, some database is in an unexpected state.

And:

```cmd
schtasks /Query /TN SqlBackupTools-RestoreCycle /V /FO LIST | findstr /R "Last.Run Last.Result Next.Run Status"
```

`Last Result: 0` = success; anything else = failure.

---

## 3. Common failures and how to fix them

### 3.1 Restore-cycle task failed (Last Result ≠ 0)

**Symptom.** Digest RED, "Last result" non-zero. The restore cycle isn't
running.

**First-line diagnostic.** Look at the most recent log file:

```cmd
dir /B /O:-D C:\SqlBackupTools\logs\restore-*.log
```

First line is the newest. Open it (e.g. `notepad C:\SqlBackupTools\logs\restore-<date>.log`)
and find where it broke. Typical errors:

| What you see | What it means | Where to look |
|---|---|---|
| `Login failed` | SQL Server permissions broken | Section 3.6 |
| `Cannot open device` | A `.trn` or `.bak` file isn't readable | Section 3.2 |
| `LSN ... too recent` | LSN chain break | Section 3.4 |
| `Disk full` / `not enough space` | Out of disk | Section 3.5 |
| `Timeout expired` | SQL Server is heavily loaded | Wait 5 min, check again |

**Run it manually.** If the log doesn't clarify, run the cycle by hand
and watch it live:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File C:\SqlBackupTools\reserv-restore-cycle.ps1
```

Let it run to completion and watch for warnings on screen.

---

### 3.2 LOG files aren't reaching RESERV

**Symptom.** One or more databases in the RPO outliers list, all lagging
by roughly the same amount (e.g. 90 min). Means the files aren't arriving.

**Diagnostic.** Look in `\\10.0.0.47\SqlBackup\<primary>\<db>\LOG\`:

```cmd
dir C:\SqlBackup\PREMIUM-2022\<db>\LOG\ | findstr ".trn"
```

Check the most recent timestamp. If it's more than 30 minutes ago (we run
on a 15-min LOG schedule), the primaries aren't producing them.

**What to do.** On the primary (PREMIUM-2022 or SQL-2022), check Ola's
LOG job:

1. Connect with SSMS to the primary as sysadmin.
2. Object Explorer → SQL Server Agent → Jobs → `DatabaseBackup - USER_DATABASES - LOG`.
3. Right-click → "View History" — was the last run successful?
4. If not, look at the step output and `master.dbo.CommandLog`.

If the LOG job won't start at all, you have a bigger problem — call Ingmar
or kick the SQL Agent:

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'DatabaseBackup - USER_DATABASES - LOG';
```

### 3.3 One specific database is lagging (others are fine)

**Symptom.** One or two databases in the RPO outliers list, the other ~150
are OK. LOG files reach RESERV but aren't being applied.

**Diagnostic.** Confirm the LOG files are actually there:

```cmd
dir C:\SqlBackup\PREMIUM-2022\<problem-db>\LOG\
```

If yes (new `.trn` within the last 15 min) but no apply — most likely an
**LSN chain break**. See next section.

### 3.4 LSN chain break

**Symptom.** A specific database falls further and further behind. The log
file shows something like *"This backup set cannot be applied because the
database has not been rolled forward far enough"* or *"LSN too recent"*.

**What to do.** The database needs to be re-seeded — take a fresh FULL on
the primary, restore it on RESERV `WITH NORECOVERY`. Manual work. Steps:

1. **On the primary** (assume PREMIUM-2022):
   ```sql
   EXEC master.dbo.DatabaseBackup
       @Databases = '<db_name>',
       @Directory = '\\10.0.0.47\SqlBackup',
       @BackupType = 'FULL',
       @Verify = 'Y', @Compress = 'Y', @CheckSum = 'Y',
       @Encrypt = 'Y', @EncryptionAlgorithm = 'AES_256',
       @ServerCertificate = 'SqlBackupCert',
       @CleanupTime = 720, @LogToTable = 'Y';
   ```

2. **On RESERV**, drop the old copy and restore the new FULL:
   ```sql
   USE master;
   ALTER DATABASE [<db_name>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
   DROP DATABASE [<db_name>];
   RESTORE DATABASE [<db_name>]
   FROM DISK = N'C:\SqlBackup\PREMIUM-2022\<db>\FULL\<new-FULL-file>.bak'
   WITH NORECOVERY, REPLACE, CHECKSUM,
        MOVE N'<data-logical-name>' TO N'C:\Data\<db_name>.mdf',
        MOVE N'<log-logical-name>'  TO N'C:\Data\<db_name>_log.ldf';
   ```

   Logical file names: `RESTORE FILELISTONLY FROM DISK = N'<file-path>';`.

3. The next restore-cycle run (within 5 min) will start applying LOGs.

**Worked example** from 2026-05-11 (`amphorafw_infohaldus`): see git
commit `63479d1` and the patterns in `ops/runbooks/dev-clone-on-workstation.md`.

### 3.5 RESERV disk full

**Symptom.** Log shows `Disk full`, or the digest's "Free %" is below 10%.

**Quick mitigation:**

1. See where the space is going:
   ```powershell
   Get-ChildItem C:\SqlBackup -Directory | ForEach-Object {
       $size = (Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum
       [pscustomobject]@{Path=$_.Name; GB=[math]::Round($size/1GB,1)}
   } | Sort-Object GB -Descending | Format-Table
   ```

2. **Don't delete `.trn` files by hand** — Ola handles retention itself
   via `@CleanupTime = 720` (30 days), but only files it knows about.

3. If you need to free space fast:
   - Delete old **MONTHLY** and **YEARLY** backups from
     `C:\SqlBackup\<primary>\<db>\FULL\` (old-dated `.bak` files) —
     **but only ones that have already been successfully applied on RESERV**.
   - **Never touch** database files (`C:\Data\*.mdf`, `*.ldf`).

4. Long-term fix: add a disk. RESERV currently has only `C:` (16.5 TB)
   and `H:` (HyperV, 4.9 TB). A new SSD volume `D:` could host
   `C:\SqlBackup\` (move + repoint).

### 3.6 SQL Server permissions broken (error 3110)

**Symptom.** Log shows *"User does not have permission to RESTORE database"*,
SQL error 3110.

**Fix.**

```sql
USE master;
ALTER SERVER ROLE [sysadmin] ADD MEMBER [NT AUTHORITY\SYSTEM];
GO
SELECT IS_SRVROLEMEMBER('sysadmin', 'NT AUTHORITY\SYSTEM');  -- must return 1
```

Cause: hardening baseline removed `BUILTIN\Administrators → sysadmin`, so
SYSTEM no longer inherits sysadmin. The restore-cycle task runs as SYSTEM.
Details: `ops/runbooks/observability-handoff.md` "Gotcha #7".

---

## 4. Big trouble — a primary is gone

**Symptom.** PREMIUM-2022 or SQL-2022 doesn't respond at all — hardware
failure, datacentre fire, ransomware, whatever.

**Do immediately:**

1. **Don't panic.** RESERV-2025 holds a fresh copy of every database (up
   to 20 minutes old depending on LOG cadence). Data isn't lost.
2. **Don't run `RESTORE WITH RECOVERY` on RESERV without a plan.** The
   moment RESERV databases are `ONLINE` (not `RESTORING`), no further
   primary-side LOGs can be applied — the chain has been closed.
3. **Assess.** Is the primary coming back soon (within an hour)? If yes:
   wait, don't act in panic. If no / unsure / confirmed loss — go to the
   next item.

**Failover to RESERV** (full procedure):

Keep `ops/runbooks/failover.md` open. In brief:

1. Make sure the latest LOGs from the primary have reached RESERV
   (run the restore cycle manually).
2. `RESTORE DATABASE <db> WITH RECOVERY` for each database.
   SqlBackupTools has a `--runRecovery` flag for the bulk case.
3. Fix `@@SERVERNAME` if the name should change.
4. Repoint application DNS / connection strings to RESERV-2025.
5. Smoke-test a query against each major application's database.

**Warning.** If you're not 100% sure what you're doing, **call Ingmar
first**. DR failover is high-impact and not automatically reversible.

---

## 5. What NOT to do, even if it looks necessary

- **Don't delete** any database on RESERV without checking whether it's
  intentionally left out (`amphora_logs_13`, for instance, is deliberately
  skipped — see comments in `reserv-restore-cycle.ps1`).
- **Don't run** `RESTORE WITH RECOVERY` on RESERV unless you're *certain*
  failover is the right action right now. Once recovered to `ONLINE`,
  the chain can't accept further LOGs — that's the closing step.
- **Don't shrink** `.mdf` files in `C:\Data\`. See
  `ops/runbooks/amphorabackend.md` for why shrinking is generally a bad
  idea.
- **Don't pause** the `SqlBackupTools-RestoreCycle` task "temporarily"
  unless you've set a reminder to re-enable it. Every paused hour means
  staler data on RESERV.
- **Don't edit** Ola jobs on the primaries (`DatabaseBackup - USER_DATABASES - LOG/FULL/DIFF`)
  without consulting `ops/phases/04-wire-jobs/main-jobs.sql`. Changes
  apply on the next `ops/run.ps1` run and overwrite your manual edits.

---

## 6. The digest doesn't arrive

**Symptom.** One or more mornings without a mail to `ingmar@interinx.com`.

**Diagnostics:**

1. Is the Task Scheduler task firing on RESERV?
   ```cmd
   schtasks /Query /TN SqlBackupTools-DRDigest /V /FO LIST | findstr /R "Last.Run Last.Result Next.Run Status"
   ```
   `Last Result: 0` = ran successfully; `Next Run Time` should show
   tomorrow at 08:00.

2. SMTP relay reachable?
   ```powershell
   Test-NetConnection mail.datanet.ee -Port 25
   ```
   Should return `TcpTestSucceeded: True`.

3. Check spam folder.

4. If all of the above looks fine but no mail — run the digest by hand:
   ```cmd
   powershell -NoProfile -ExecutionPolicy Bypass -File C:\SqlBackupTools\dr-digest.ps1
   ```
   Watch for any error message.

---

## 7. Deeper detail — where to look

| You want to know | Where it is |
|---|---|
| System architecture, "what's been done" | `ops/runbooks/observability-handoff.md` |
| All-phases checklist, in order | `ops/GETTING-STARTED.md` |
| Per-server config | `ops/config/<server-name>.ps1` |
| Full failover procedure | `ops/runbooks/failover.md` |
| RESERV restore-cycle script | `ops/runbooks/reserv-restore-cycle.ps1` |
| Digest script | `ops/runbooks/dr-digest.ps1` |
| `AmphoraBackend` (separate DB on SQL-2022 second instance, **NOT in DR**) | `ops/runbooks/amphorabackend.md` |
| Workstation dev clones | `ops/runbooks/dev-clone-on-workstation.md` |

---

## 8. Contacts

- **Ingmar (primary owner)** — Slack / phone
- **Repo** — `https://github.com/amphora-infohaldus/SqlBackupTools`
- **RESERV-2025 SSH** — `ssh -i %USERPROFILE%\.ssh\claude_ai_ed25519 svc_claude_ssh@10.0.0.47`
- **Primary IPs** — PREMIUM-2022 = `10.0.0.45`, SQL-2022 = `10.0.0.35`,
  RESERV-2025 = `10.0.0.47`

---

## Closing note

The system is designed so that **a green day is every day**. If you see
amber or red and you're unsure what to do — paging Ingmar is always better
than guessing at keystrokes. Database recovery operations are often
irreversible.

Last updated: 2026-05-11.
