-- Why is this database in SIMPLE recovery model?
--
-- Run on the SOURCE primary (PREMIUM-2022 or SQL-2022) where the database
-- lives, not on RESERV-2025. Paste into SSMS, change @DB if needed, F5.
--
-- Sections:
--   1. Current state of @DB
--   2. Default trace -- ALTER DATABASE events for @DB
--   3. SQL Server error log -- "Setting database option RECOVERY" lines
--   4. Backup-type history for @DB (D=full, I=diff, L=log)
--   5. Cohort -- other SIMPLE databases on this instance
--   6. Ola Hallengren CommandLog (if installed) -- ALTER DATABASE history

SET NOCOUNT ON;
DECLARE @DB sysname = N'amphorafw_infohaldus';

PRINT N'======================================================================';
PRINT N'Investigation target: ' + @DB + N' on ' + @@SERVERNAME;
PRINT N'======================================================================';

------------------------------------------------------------------------
PRINT N'';
PRINT N'### 1. Current state of ' + @DB + N' ###';
------------------------------------------------------------------------
SELECT
    d.name,
    d.state_desc,
    d.recovery_model_desc,
    d.compatibility_level,
    d.create_date,
    SUSER_SNAME(d.owner_sid)        AS owner_login,
    d.is_read_only,
    d.is_auto_close_on,
    d.is_auto_shrink_on,
    d.collation_name
FROM sys.databases d
WHERE d.name = @DB;

-- Last successful backup of each type
SELECT
    bs.type,
    CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE bs.type END AS type_desc,
    MAX(bs.backup_finish_date) AS last_taken,
    COUNT(*) AS total_backups
FROM msdb.dbo.backupset bs
WHERE bs.database_name = @DB
GROUP BY bs.type
ORDER BY bs.type;

------------------------------------------------------------------------
PRINT N'';
PRINT N'### 2. Default trace -- ALTER DATABASE events for ' + @DB + N' ###';
PRINT N'(Default trace rolls over ~5x20MB; old changes may be gone.)';
------------------------------------------------------------------------
DECLARE @trace_path nvarchar(260) =
    (SELECT REVERSE(SUBSTRING(REVERSE(path), CHARINDEX(N'\', REVERSE(path)), 260)) + N'log.trc'
     FROM sys.traces WHERE is_default = 1);

IF @trace_path IS NULL
    PRINT N'No default trace running -- skipping.';
ELSE
BEGIN
    SELECT
        t.StartTime,
        t.LoginName,
        t.HostName,
        t.ApplicationName,
        t.DatabaseName,
        te.name AS event_class,
        t.TextData
    FROM sys.fn_trace_gettable(@trace_path, DEFAULT) t
    JOIN sys.trace_events te ON t.EventClass = te.trace_event_id
    WHERE
        t.DatabaseName = @DB
        AND (
            t.TextData LIKE N'%RECOVERY%'
            OR te.name IN (N'Audit Database Management Event', N'Object:Altered')
        )
    ORDER BY t.StartTime DESC;
END

------------------------------------------------------------------------
PRINT N'';
PRINT N'### 3. SQL error log -- "Setting database option RECOVERY" lines ###';
PRINT N'(Reads current + 6 archived logs.)';
------------------------------------------------------------------------
DECLARE @errlog_results TABLE (LogDate datetime, ProcessInfo nvarchar(50), Text nvarchar(max));
DECLARE @i int = 0;
WHILE @i <= 6
BEGIN
    BEGIN TRY
        INSERT INTO @errlog_results (LogDate, ProcessInfo, Text)
        EXEC sp_readerrorlog @i, 1, N'Setting database option RECOVERY';
    END TRY
    BEGIN CATCH
        -- log file @i may not exist
    END CATCH
    SET @i += 1;
END

SELECT LogDate, Text
FROM @errlog_results
WHERE Text LIKE N'%' + @DB + N'%'
ORDER BY LogDate DESC;

------------------------------------------------------------------------
PRINT N'';
PRINT N'### 4. Backup-type history for ' + @DB + N' (by year) ###';
PRINT N'(If LOG count is always 0, the DB has never been in FULL recovery.)';
------------------------------------------------------------------------
SELECT
    DATEPART(YEAR,  bs.backup_finish_date) AS yr,
    DATEPART(MONTH, bs.backup_finish_date) AS mo,
    SUM(CASE WHEN bs.type = 'D' THEN 1 ELSE 0 END) AS full_count,
    SUM(CASE WHEN bs.type = 'I' THEN 1 ELSE 0 END) AS diff_count,
    SUM(CASE WHEN bs.type = 'L' THEN 1 ELSE 0 END) AS log_count
FROM msdb.dbo.backupset bs
WHERE bs.database_name = @DB
GROUP BY DATEPART(YEAR, bs.backup_finish_date), DATEPART(MONTH, bs.backup_finish_date)
ORDER BY yr DESC, mo DESC;

------------------------------------------------------------------------
PRINT N'';
PRINT N'### 5. Cohort -- other SIMPLE-recovery user DBs on this instance ###';
PRINT N'(Look for patterns: same owner? created together? shared name prefix?)';
------------------------------------------------------------------------
SELECT
    d.name,
    d.create_date,
    SUSER_SNAME(d.owner_sid) AS owner_login,
    d.recovery_model_desc
FROM sys.databases d
WHERE d.recovery_model_desc = 'SIMPLE'
  AND d.database_id > 4   -- exclude system DBs
ORDER BY d.create_date DESC, d.name;

SELECT
    SUSER_SNAME(d.owner_sid) AS owner_login,
    COUNT(*) AS simple_dbs
FROM sys.databases d
WHERE d.recovery_model_desc = 'SIMPLE'
  AND d.database_id > 4
GROUP BY SUSER_SNAME(d.owner_sid)
ORDER BY simple_dbs DESC;

------------------------------------------------------------------------
PRINT N'';
PRINT N'### 6. Ola Hallengren CommandLog (if installed) ###';
------------------------------------------------------------------------
IF OBJECT_ID(N'master.dbo.CommandLog', N'U') IS NULL
    PRINT N'master.dbo.CommandLog not present -- Ola maintenance solution not installed in master, or installed elsewhere.';
ELSE
BEGIN
    SELECT TOP 100
        cl.StartTime,
        cl.DatabaseName,
        cl.CommandType,
        cl.Command,
        cl.ErrorNumber,
        cl.ErrorMessage
    FROM master.dbo.CommandLog cl
    WHERE cl.DatabaseName = @DB
      AND (cl.Command LIKE N'%RECOVERY%' OR cl.CommandType LIKE N'%ALTER%')
    ORDER BY cl.StartTime DESC;

    -- Also: did Ola ever attempt LOG backups for this DB?
    SELECT TOP 20
        cl.StartTime,
        cl.CommandType,
        cl.ErrorNumber,
        cl.ErrorMessage
    FROM master.dbo.CommandLog cl
    WHERE cl.DatabaseName = @DB
      AND cl.CommandType IN (N'BACKUP_LOG', N'BACKUP_DATABASE')
    ORDER BY cl.StartTime DESC;
END

PRINT N'';
PRINT N'Done. Read top-down -- section 1 confirms current state, then 2/3 give';
PRINT N'an audit trail of WHO/WHEN, 4 shows whether LOG was ever taken, 5 puts';
PRINT N'this DB in context of any cohort, 6 surfaces Ola activity if present.';
