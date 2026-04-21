-- Phase 04b — amphora_logs dedicated local-only jobs.
--
-- amphora_logs is excluded from the main FULL/DIFF/LOG jobs (name collides
-- across both primaries, so it can't live on one RESERV instance). Instead:
--   - Revert to SIMPLE recovery (no LOG needed — app recreates it if missing;
--     Alloy ships errors to Kubernetes)
--   - Weekly FULL + daily DIFF locally (30d retention on PREMIUM, 14d on
--     SQL-2022 per tier)
--   - MONTHLY + YEARLY jobs include amphora_logs (local, for 1-year SOAP
--     message retention + yearly offsite forever via RichCopy)
--
-- Run AFTER phases/04-wire-jobs/main-jobs.sql.
--
-- REQUIRED sqlcmd vars (from ops/run.ps1):
--   ServerCert, RetentionHours, AmphoraLogsLocalPath,
--   AmphoraLogsFullTime, AmphoraLogsDiffTime

SET NOCOUNT ON;

DECLARE @ServerCert              nvarchar(128) = N'$(ServerCert)';
DECLARE @RetentionHours          int           = $(RetentionHours);
DECLARE @AmphoraLogsLocalPath    nvarchar(256) = N'$(AmphoraLogsLocalPath)';
DECLARE @AmphoraLogsFullTime     int           = $(AmphoraLogsFullTime);
DECLARE @AmphoraLogsDiffTime     int           = $(AmphoraLogsDiffTime);

DECLARE @cmd nvarchar(max);

-- ==========================================================================
-- 1. Revert amphora_logs to SIMPLE recovery (idempotent)
-- ==========================================================================
IF DB_ID(N'amphora_logs') IS NOT NULL
   AND (SELECT recovery_model_desc FROM sys.databases WHERE name = N'amphora_logs') <> N'SIMPLE'
BEGIN
    ALTER DATABASE [amphora_logs] SET RECOVERY SIMPLE WITH NO_WAIT;
    PRINT 'amphora_logs -> SIMPLE.';
END
ELSE IF DB_ID(N'amphora_logs') IS NULL
    PRINT 'amphora_logs not present on this server — skipping recovery flip.';
ELSE
    PRINT 'amphora_logs already SIMPLE.';

-- ==========================================================================
-- 2. Schedules for amphora_logs jobs
-- ==========================================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'Sched_AmphoraLogs_Full_Sunday')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = N'Sched_AmphoraLogs_Full_Sunday', @force_delete = 1;
EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_AmphoraLogs_Full_Sunday',
    @enabled = 1, @freq_type = 8, @freq_interval = 1,
    @freq_recurrence_factor = 1, @active_start_time = @AmphoraLogsFullTime;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'Sched_AmphoraLogs_Diff_MonSat')
    EXEC msdb.dbo.sp_delete_schedule @schedule_name = N'Sched_AmphoraLogs_Diff_MonSat', @force_delete = 1;
EXEC msdb.dbo.sp_add_schedule @schedule_name = N'Sched_AmphoraLogs_Diff_MonSat',
    @enabled = 1, @freq_type = 8, @freq_interval = 126,  -- Mon..Sat
    @freq_recurrence_factor = 1, @active_start_time = @AmphoraLogsDiffTime;

PRINT 'Schedules for amphora_logs jobs created.';

-- Skip job creation if amphora_logs doesn't exist on this server
IF DB_ID(N'amphora_logs') IS NULL
BEGIN
    PRINT 'Skipping job creation — amphora_logs not on this server.';
    RETURN;
END

-- ==========================================================================
-- 3. amphora_logs FULL (weekly, local)
-- ==========================================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - amphora_logs - FULL')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DatabaseBackup - amphora_logs - FULL';

EXEC msdb.dbo.sp_add_job
    @job_name = N'DatabaseBackup - amphora_logs - FULL',
    @description = N'Weekly FULL for amphora_logs (local only; not shipped to RESERV standby).',
    @enabled = 1;

SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''amphora_logs'', '
 + N'@Directory = ''' + @AmphoraLogsLocalPath + N''', '
 + N'@BackupType = ''FULL'', '
 + N'@Verify = ''Y'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = ' + CAST(@RetentionHours AS nvarchar) + N', '
 + N'@LogToTable = ''Y''';
EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'DatabaseBackup - amphora_logs - FULL',
    @step_name = N'Backup', @subsystem = N'TSQL',
    @database_name = N'master', @command = @cmd;
EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'DatabaseBackup - amphora_logs - FULL';
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - amphora_logs - FULL',
    @schedule_name = N'Sched_AmphoraLogs_Full_Sunday';
PRINT 'amphora_logs FULL job (local) created.';

-- ==========================================================================
-- 4. amphora_logs DIFF (daily Mon-Sat, local)
-- ==========================================================================
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - amphora_logs - DIFF')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DatabaseBackup - amphora_logs - DIFF';

EXEC msdb.dbo.sp_add_job
    @job_name = N'DatabaseBackup - amphora_logs - DIFF',
    @description = N'Daily DIFF for amphora_logs (Mon-Sat, local only).',
    @enabled = 1;

SET @cmd = N'EXECUTE [dbo].[DatabaseBackup] '
 + N'@Databases = ''amphora_logs'', '
 + N'@Directory = ''' + @AmphoraLogsLocalPath + N''', '
 + N'@BackupType = ''DIFF'', '
 + N'@Verify = ''Y'', @Compress = ''Y'', @CheckSum = ''Y'', '
 + N'@Encrypt = ''Y'', @EncryptionAlgorithm = ''AES_256'', '
 + N'@ServerCertificate = ''' + @ServerCert + N''', '
 + N'@CleanupTime = ' + CAST(@RetentionHours AS nvarchar) + N', '
 + N'@LogToTable = ''Y''';
EXEC msdb.dbo.sp_add_jobstep
    @job_name = N'DatabaseBackup - amphora_logs - DIFF',
    @step_name = N'Backup', @subsystem = N'TSQL',
    @database_name = N'master', @command = @cmd;
EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'DatabaseBackup - amphora_logs - DIFF';
EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'DatabaseBackup - amphora_logs - DIFF',
    @schedule_name = N'Sched_AmphoraLogs_Diff_MonSat';
PRINT 'amphora_logs DIFF job (local) created.';

PRINT '';
PRINT '=== amphora_logs jobs ===';
SELECT j.name, j.enabled, LEFT(js.command, 120) AS CmdStart
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE j.name LIKE 'DatabaseBackup - amphora_logs%'
ORDER BY j.name;
