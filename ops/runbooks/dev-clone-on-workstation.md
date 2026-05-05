---
audience: internal
---

# Development clones of `amphorafw_infohaldus` on a workstation

Why this exists: bot development (e.g. the finances bot) needs two persistent
copies of `amphorafw_infohaldus` on the developer's workstation —

- **`amphorafw_infohaldus_baseline`** — `READ_ONLY`, never written. Comparison
  reference: "what did the data look like *before* my code touched it?"
- **`amphorafw_infohaldus_dev`** — read-write. Where the bot under
  development inserts invoices, runs migrations, etc. Reset whenever you
  want a clean slate.

These clones live on the **workstation**, not on RESERV-2025. The RESERV
copy of `amphorafw_infohaldus` is a different thing — it's the warm-standby
replica kept in `RESTORING` state by the continuous-restore daemon
(`ops/runbooks/reserv-continuous-restore.md`). Don't confuse them.

## Prerequisites

- SQL Server installed locally (default instance, integrated auth as a
  sysadmin — typically your workstation user).
- Network reachability to RESERV-2025 (10.0.0.47) over SSH for fetching the
  source backup.
- An age key on the workstation that's a recipient in the org `.sops.yaml`
  (only needed if you want to decrypt secrets; the local clones use
  integrated auth so this isn't strictly required for the clones themselves).

## One-time setup — import `SqlBackupCert`

Backups produced on PREMIUM-2022 are encrypted with the server certificate
`SqlBackupCert` (thumbprint `0x47FBCD3619D5A4CC2B9ABD3049BF52DDE1F4CBA9`).
Without that certificate installed in the local SQL instance,
`RESTORE FILELISTONLY` and `RESTORE DATABASE` both fail with:

> Cannot find server certificate with thumbprint '0x...'.

This is **backup encryption**, not TDE — the restored data is plaintext on
disk. But the cert is still required to decrypt the `.bak`.

Steps (do this once on the workstation, then never again — the cert
persists across restores and SQL restarts):

1. **Generate two strong passwords** (any complex strings; Windows password
   policy requires upper + lower + digit + symbol). One protects the cert
   export in transit; the other is the destination's database master key.
   Both can be discarded after the import — neither is needed for ongoing
   operations because SQL Server protects the master key with the service
   master key.

2. **Export the cert + private key on RESERV** (paste in SSMS as sysadmin):

   ```sql
   USE master;
   BACKUP CERTIFICATE [SqlBackupCert]
     TO FILE = 'C:\Temp\SqlBackupCert.cer'
     WITH PRIVATE KEY (
       FILE = 'C:\Temp\SqlBackupCert.pvk',
       ENCRYPTION BY PASSWORD = '<XPORT_PWD>'
     );
   ```

3. **Copy both files to the workstation** (e.g. `scp -O` from RESERV's
   `C:\Temp\` to the workstation's `C:\BackupSource\`).

4. **Import on the workstation** (paste in SSMS as sysadmin):

   ```sql
   USE master;
   IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
       CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<MK_PWD>';

   CREATE CERTIFICATE [SqlBackupCert]
     FROM FILE = 'C:\BackupSource\SqlBackupCert.cer'
     WITH PRIVATE KEY (
       FILE = 'C:\BackupSource\SqlBackupCert.pvk',
       DECRYPTION BY PASSWORD = '<XPORT_PWD>'
     );
   ```

5. **Delete the export files immediately** from both boxes:

   ```powershell
   # Workstation
   Remove-Item C:\BackupSource\SqlBackupCert.cer, C:\BackupSource\SqlBackupCert.pvk -Force

   # RESERV (over ssh)
   ssh svc_claude_ssh@10.0.0.47 'powershell Remove-Item C:\Temp\SqlBackupCert.cer,C:\Temp\SqlBackupCert.pvk -Force'
   ```

   The cert is now persistently installed in the workstation's SQL
   instance — encrypted by the local service master key, no password
   needed for ongoing use.

## Repeated use — restore (or reset) a clone

1. **Fetch a fresh `.bak` from RESERV** (skip if the existing one in
   `C:\BackupSource\` is recent enough):

   ```bash
   scp -O svc_claude_ssh@10.0.0.47:'C:/SqlBackup/PREMIUM-2022/amphorafw_infohaldus/FULL/PREMIUM-2022_amphorafw_infohaldus_FULL_<yyyymmdd_hhmmss>.bak' /c/BackupSource/
   ```

   The `-O` flag picks the legacy SCP protocol; the default SFTP path is
   flaky on Windows OpenSSH for multi-GB binaries.

2. **Run the restore script:**

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Sources\SqlBackupTools\ops\runbooks\restore-clone.ps1 -Target baseline
   powershell -ExecutionPolicy Bypass -File C:\Sources\SqlBackupTools\ops\runbooks\restore-clone.ps1 -Target dev
   ```

   The script picks the newest `.bak` whose filename contains the source
   DB from `C:\BackupSource\` (override with `-BackupPath`), drops the
   named clone if it exists, and restores `WITH RECOVERY` to
   `C:\Data\dev\<dbname>.mdf` (override with `-DataDir`). `baseline` is
   set `READ_ONLY` at the end; `dev` is read-write. Default `-SourceDb`
   is `amphorafw_infohaldus`; pass `-SourceDb` to clone other tenants —
   see "Other tenants as READ_ONLY clones" below.

3. **The bot's connection string** (from any local process, no password):

   ```
   Server=.;Integrated Security=true;Database=amphorafw_infohaldus_dev;TrustServerCertificate=true
   ```

   Same shape for `amphorafw_infohaldus_baseline` (READ_ONLY).

## Source recovery model is `FULL`, but no LOG chain ships

The clones come up in `FULL` recovery model — the source on PREMIUM-2022
*is* in FULL, contrary to the working assumption that the SIMPLE-recovery
cohort included this DB. But the backup folder
`C:\SqlBackup\PREMIUM-2022\amphorafw_infohaldus\` has no `LOG/` subfolder,
meaning Ola's LOG-backup job is excluding this DB for some reason. RPO at
restore time is therefore bounded by the most recent FULL — typically the
overnight 04:11 run, so `~now − last 04:11`.

Why this DB is excluded from LOG backups: not yet determined. Run
`ops/runbooks/why-simple-recovery.sql` against PREMIUM-2022 to investigate
(Ola CommandLog section is the most likely informative one).

## Other tenants as READ_ONLY clones

Same script supports loading any tenant DB as a single READ_ONLY local
copy (no `_baseline`/`_dev` pair). Use `-Target readonly` and pass
`-SourceDb`. The clone is named exactly the same as the source DB.

The source `.bak` for tenants other than `amphorafw_infohaldus` lives
under `C:\SqlBackup\SQL-2022\<source>\FULL\` on RESERV (most non-PREMIUM
tenants ship to SQL-2022; check both primaries' folders if unsure).

```bash
# scp the .bak (size varies — many tenants are 10+ GB)
scp -O svc_claude_ssh@10.0.0.47:'C:/SqlBackup/SQL-2022/amphorafw_hiiumaavv/FULL/SQL-2022_amphorafw_hiiumaavv_FULL_<yyyymmdd_hhmmss>.bak' /c/BackupSource/
scp -O svc_claude_ssh@10.0.0.47:'C:/SqlBackup/SQL-2022/amphorafw_haapsalulv/FULL/SQL-2022_amphorafw_haapsalulv_FULL_<yyyymmdd_hhmmss>.bak' /c/BackupSource/
```

```powershell
powershell -ExecutionPolicy Bypass -File C:\Sources\SqlBackupTools\ops\runbooks\restore-clone.ps1 -SourceDb amphorafw_hiiumaavv  -Target readonly
powershell -ExecutionPolicy Bypass -File C:\Sources\SqlBackupTools\ops\runbooks\restore-clone.ps1 -SourceDb amphorafw_haapsalulv -Target readonly
```

Connection string:

```
Server=.;Integrated Security=true;Database=amphorafw_hiiumaavv;TrustServerCertificate=true
```

Cleanup is the same `ALTER DATABASE … SINGLE_USER` → `DROP DATABASE`
shape as for the dev pair, just against the bare source name.

## Cleaning up

To drop the clones entirely (e.g. you're done with this dev work):

```sql
USE master;
ALTER DATABASE [amphorafw_infohaldus_baseline] SET READ_WRITE WITH ROLLBACK IMMEDIATE;
ALTER DATABASE [amphorafw_infohaldus_baseline] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [amphorafw_infohaldus_baseline];

ALTER DATABASE [amphorafw_infohaldus_dev] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [amphorafw_infohaldus_dev];
```

`DROP DATABASE` removes the `.mdf`/`.ldf` files automatically. The
`SqlBackupCert` certificate stays installed — leave it; the next time you
need clones it saves you the export/import dance.

## See also

- `ops/runbooks/restore-clone.ps1` — the script described above.
- `ops/runbooks/why-simple-recovery.sql` — diagnostic for the missing
  LOG-backup chain on PREMIUM-2022.
- `ops/runbooks/reserv-continuous-restore.md` — the daemon-managed copy on
  RESERV (different beast; don't conflate).
- `ops/runbooks/failover.md` — production failover (also requires
  `SqlBackupCert` on the destination, same export/import pattern).
