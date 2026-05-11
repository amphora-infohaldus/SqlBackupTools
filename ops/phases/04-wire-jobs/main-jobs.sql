-- Phase 04 — Wire the main SQL Agent jobs on this primary.
--
-- Values are sqlcmd variables (`$(...)`), injected by `ops\run.ps1` from
-- per-server config. Defaults below (`:setvar`) are placeholders — the
-- wrapper overrides all of them via sqlcmd -v.
--
-- What this script does (idempotent):
--   1. Creates 5 schedules.
--   2. Updates the 3 Ola default jobs (FULL, DIFF, LOG) — new step command
--      pointing at local ShipLocalPath, new exclusion list, new schedule.
--   3. (Re)creates MONTHLY and YEARLY jobs (local paths, long retention).
--   4. LOG job is WIRED but left DISABLED — Phase 06 enables after seed.
--
-- All commands use bare `EXECUTE [dbo].[DatabaseBackup] ...` in TSQL
-- subsystem (not sqlcmd wrappers). See notes at end of file for why.
--
-- REQUIRED sqlcmd variables (injected by ops/run.ps1 via -v KEY=VALUE):
--   ServerCert           — cert name ('SqlBackupCert' on PREMIUM/RESERV, 'MyCertificate' on SQL-2022)
--   RetentionHours       — 336 (Standard 14d) or 720 (Premium 30d)
--   WeeklyFullTime       — HHMMSS int, e.g. 20000 for 02:00
--   DailyDiffTime        — HHMMSS int
--   MonthlyFullTime      — HHMMSS int
--   YearlyFullTime       — HHMMSS int
--   LogIntervalMinutes   — integer; currently 15 (was 30 at first rollout)
--   ShipLocalPath        — e.g. 'W:\SqlBackup\ship' or 'D:\SqlBackup\ship'
--   MonthlyLocalPath     — local monthly root
--   YearlyLocalPath      — local yearly root
--   ExcludeListShip      — Ola @Databases for RESERV-bound jobs
--   ExcludeListLocal     — Ola @Databases for MONTHLY/YEARLY (keeps amphora_logs)
--   MonthlyStartDate     — YYYYMMDD int, first fire of monthly schedule
--   YearlyStartDate      — YYYYMMDD int, first fire of yearly schedule
--
-- DO NOT add :setvar defaults in this file — :setvar has HIGHER precedence
-- than sqlcmd -v, so defaults would silently override the wrapper's values.
-- The wrapper (run.ps1) validates that every required var is present before
-- executing sqlcmd.

SET NOCOUNT ON;

-- ---- Resolve the sqlcmd vars into T-SQL ----
DECLARE @ServerCert          nvarchar(128) = N'$(ServerCert)';
DECLARE @RetentionHours      int           = $(RetentionHours);
DECLARE @WeeklyFullTime      int           = $(WeeklyFullTime);
DECLARE @DailyDiffTime       int           = $(DailyDiffTime);
DECLARE @MonthlyFullTime     int           = $(MonthlyFullTime);
DECLARE @YearlyFullTime      int           = $(YearlyFullTime);
DECLARE @LogIntervalMinutes  int           = $(LogIntervalMinutes);
DECLARE @ShipLocalPath       nvarchar(256) = N'$(ShipLocalPath)';
DECLARE @MonthlyLocalPath    nvarchar(256) = N'$(MonthlyLocalPath)';
DECLARE @YearlyLocalPath     nvarchar(256) = N'$(YearlyLocalPath)';
DECLARE @ExcludeListShip     nvarchar(512) = N'$(ExcludeListShip)';
DECLARE @ExcludeListLocal    nvarchar(512) = N'$(ExcludeListLocal)';
DECLARE @MonthlyStartDate    int           = $(MonthlyStartDate);
DECLARE @YearlyStartDate     int           = $(YearlyStartDate);

DECLARE @cmd nvarchar(max);
DECLARE @jobId uniqueidentifier;

-- ==========================================================================
-- 1. Schedules (idempotent — delete-and-recreate)
-- ==========================================================================
DECLARE @scheds TABLE (name sysname);
INSERT @scheds VALUES
    (N'Sched_Weekly_Full'), (N'Sched_Daily_Diff'), (N'Sched_Every_N_Min_Log'),
    (N'Sched_Monthly_Full'), (N'Sched_Yearly_Full');

DECLARE @sn sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @scheds;
OPEN c; FETCH NEXT FROM c INTO @sn;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = @sn)
        EXEC msdb.dbo.sp_delete_schedule @schedule_name = @sn, @force_delete = 1;
    FETCH NEXT FROM c INTO @sn;
END
CLOSE c; DEALLOCATE c;

EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_Weekly_Full',
    @enabled = 1, @freq_type = 8, @freq_interval = 1,
    @freq_recurrence_factor = 1, @active_start_time = @WeeklyFullTime;

EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_Daily_Diff',
    @enabled = 1, @freq_type = 8, @freq_interval = 126,  -- Mon..Sat
    @freq_recurrence_factor = 1, @active_start_time = @DailyDiffTime;

EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_Every_N_Min_Log',
    @enabled = 1, @freq_type = 4, @freq_interval = 1,
    @freq_subday_type = 4, @freq_subday_interval = @LogIntervalMinutes,
    @active_start_time = 0, @active_end_time = 235959;

EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_Monthly_Full',
    @enabled = 1, @freq_type = 16, @freq_interval = 1,
    @freq_recurrence_factor = 1, @active_start_time = @MonthlyFullTime,
    @active_start_date = @MonthlyStartDate;

EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_Yearly_Full',
    @enabled = 1, @freq_type = 16, @freq_interval = 1,
    @freq_recurrence_factor = 12, @active_start_time = @YearlyFullTime,
    @active_start_date = @YearlyStartDate;

PRINT '1. Schedules created.';

-- ==========================================================================
-- 2. Weekly FULL — writes to @ShipLocalPath (direct UNC to RESERV on PREMIUM-2022)
-- ==========================================================================
SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''' + @ExcludeListShip + N''', '
 + N'@Directory = ''' + @ShipLocalPath + N''', '
 + N'@BackupType = ''FULL'', '
 + N'@Verify = ''Y'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = ' + CAST(@RetentionHours AS nvarchar) + N', '
 + N'@LogToTable = ''Y''';
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL',
    @step_id = 1, @subsystem = N'TSQL', @database_name = N'master', @command = @cmd;

SET @jobId = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - FULL');
DELETE FROM msdb.dbo.sysjobschedules WHERE job_id = @jobId;
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL',
    @schedule_name = N'Sched_Weekly_Full';
EXEC msdb.dbo.sp_update_job
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL', @enabled = 1;
PRINT '2. Weekly FULL wired + enabled.';

-- ==========================================================================
-- 3. Daily DIFF
-- ==========================================================================
SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''' + @ExcludeListShip + N''', '
 + N'@Directory = ''' + @ShipLocalPath + N''', '
 + N'@BackupType = ''DIFF'', '
 + N'@Verify = ''Y'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = ' + CAST(@RetentionHours AS nvarchar) + N', '
 + N'@LogToTable = ''Y''';
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'DatabaseBackup - USER_DATABASES - DIFF',
    @step_id = 1, @subsystem = N'TSQL', @database_name = N'master', @command = @cmd;

SET @jobId = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - DIFF');
DELETE FROM msdb.dbo.sysjobschedules WHERE job_id = @jobId;
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - USER_DATABASES - DIFF',
    @schedule_name = N'Sched_Daily_Diff';
EXEC msdb.dbo.sp_update_job
    @job_name = N'DatabaseBackup - USER_DATABASES - DIFF', @enabled = 1;
PRINT '3. Daily DIFF wired + enabled.';

-- ==========================================================================
-- 4. LOG — wired but DISABLED. Phase 6 enables after initial seed.
-- ==========================================================================
SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''' + @ExcludeListShip + N''', '
 + N'@Directory = ''' + @ShipLocalPath + N''', '
 + N'@BackupType = ''LOG'', '
 + N'@Verify = ''N'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = ' + CAST(@RetentionHours AS nvarchar) + N', '
 + N'@LogToTable = ''Y''';
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'DatabaseBackup - USER_DATABASES - LOG',
    @step_id = 1, @subsystem = N'TSQL', @database_name = N'master', @command = @cmd;

SET @jobId = (SELECT job_id FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - LOG');
DELETE FROM msdb.dbo.sysjobschedules WHERE job_id = @jobId;
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - USER_DATABASES - LOG',
    @schedule_name = N'Sched_Every_N_Min_Log';
EXEC msdb.dbo.sp_update_job
    @job_name = N'DatabaseBackup - USER_DATABASES - LOG', @enabled = 0;
PRINT '4. LOG job wired (DISABLED — phase 06 enables).';

-- ==========================================================================
-- 5. MONTHLY FULL — local on primary, 30 day retention, picked up by offsite RichCopy job for 1-year obligation
-- ==========================================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - FULL - MONTHLY')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DatabaseBackup - USER_DATABASES - FULL - MONTHLY';

EXEC msdb.dbo.sp_add_job
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - MONTHLY',
    @description = N'Monthly FULL (local). 30d local retention; RichCopy ships offsite for 1-year obligation.',
    @enabled = 1;

SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''' + @ExcludeListLocal + N''', '
 + N'@Directory = ''' + @MonthlyLocalPath + N''', '
 + N'@BackupType = ''FULL'', '
 + N'@Verify = ''Y'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = 720, @LogToTable = ''Y''';
EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - MONTHLY',
    @step_name = N'DatabaseBackup MONTHLY', @subsystem = N'TSQL',
    @database_name = N'master', @command = @cmd;
EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - MONTHLY';
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - MONTHLY',
    @schedule_name = N'Sched_Monthly_Full';
PRINT '5. MONTHLY job created.';

-- ==========================================================================
-- 6. YEARLY FULL — local, 30d retention; offsite keeps forever
-- ==========================================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - FULL - YEARLY')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DatabaseBackup - USER_DATABASES - FULL - YEARLY';

EXEC msdb.dbo.sp_add_job
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - YEARLY',
    @description = N'Yearly FULL (local). 30d local; RichCopy ships offsite for indefinite retention.',
    @enabled = 1;

SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''' + @ExcludeListLocal + N''', '
 + N'@Directory = ''' + @YearlyLocalPath + N''', '
 + N'@BackupType = ''FULL'', '
 + N'@Verify = ''Y'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = 720, @LogToTable = ''Y''';
EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - YEARLY',
    @step_name = N'DatabaseBackup YEARLY', @subsystem = N'TSQL',
    @database_name = N'master', @command = @cmd;
EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - YEARLY';
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - USER_DATABASES - FULL - YEARLY',
    @schedule_name = N'Sched_Yearly_Full';
PRINT '6. YEARLY job created.';

-- ==========================================================================
-- Inventory
-- ==========================================================================
PRINT '';
PRINT '=== Backup-job inventory ===';
SELECT j.name, j.enabled, js.subsystem, js.database_name, LEFT(js.command, 100) AS CmdStart
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE j.name LIKE 'DatabaseBackup - USER_DATABASES%'
ORDER BY j.name;

-- NOTE on subsystem choice:
-- Ola's default jobs ship with subsystem='TSQL' and database_name='master'.
-- We preserve that — the step runs the bare EXECUTE statement directly. Past
-- attempts that wrapped in `sqlcmd -E -S $(ESCAPE_SQUOTE(SRVR)) -Q "..."`
-- failed because (a) the subsystem remained TSQL so the T-SQL parser choked
-- on "sqlcmd -E" with `Incorrect syntax near 'E'`, and (b) sqlcmd itself
-- eats $(...) tokens at load time unless -x is passed. Bare EXEC avoids
-- both traps.
