SET NOCOUNT ON;

PRINT '=== [1] INSTANCE ==='
SELECT
    @@SERVERNAME                            AS ServerName,
    CAST(SERVERPROPERTY('MachineName') AS sysname)   AS MachineName,
    CAST(SERVERPROPERTY('InstanceName') AS sysname)  AS InstanceName,
    CAST(SERVERPROPERTY('ProductVersion') AS varchar(32)) AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel')   AS varchar(32)) AS ProductLevel,
    CAST(SERVERPROPERTY('Edition')        AS varchar(64)) AS Edition,
    CAST(SERVERPROPERTY('Collation')      AS sysname)     AS ServerCollation,
    CAST(SERVERPROPERTY('IsClustered')    AS int)         AS IsClustered,
    CAST(SERVERPROPERTY('IsHadrEnabled')  AS int)         AS IsHadrEnabled;

PRINT '=== [2] DATABASES ==='
SELECT
    d.name, d.state_desc, d.recovery_model_desc, d.is_read_only,
    d.compatibility_level, d.collation_name, d.is_encrypted,
    d.is_cdc_enabled, d.is_broker_enabled, d.log_reuse_wait_desc,
    d.containment_desc, d.create_date
FROM sys.databases d
WHERE d.database_id > 4
ORDER BY d.name;

PRINT '=== [3] DBs NOT IN FULL (need switch) ==='
SELECT name, recovery_model_desc
FROM sys.databases
WHERE database_id > 4 AND recovery_model_desc <> 'FULL'
ORDER BY name;

PRINT '=== [4] DB SIZES (MB) ==='
SELECT
    DB_NAME(mf.database_id) AS DbName,
    SUM(CASE WHEN mf.type = 0 THEN mf.size * 8.0 / 1024 END) AS DataMB,
    SUM(CASE WHEN mf.type = 1 THEN mf.size * 8.0 / 1024 END) AS LogMB,
    COUNT(CASE WHEN mf.type = 0 THEN 1 END) AS DataFiles,
    COUNT(CASE WHEN mf.type = 1 THEN 1 END) AS LogFiles
FROM sys.master_files mf
WHERE mf.database_id > 4
GROUP BY mf.database_id
ORDER BY DataMB DESC;

PRINT '=== [5] FILE PATHS ==='
SELECT DB_NAME(mf.database_id) AS DbName, mf.type_desc, mf.name AS LogicalName, mf.physical_name
FROM sys.master_files mf
WHERE mf.database_id > 4
ORDER BY 1, mf.type, mf.file_id;

PRINT '=== [6] LAST BACKUPS PER DB (30d window) ==='
;WITH lb AS (
    SELECT bs.database_name, bs.type, bs.backup_finish_date, bmf.physical_device_name,
           ROW_NUMBER() OVER (PARTITION BY bs.database_name, bs.type ORDER BY bs.backup_finish_date DESC) rn
    FROM msdb.dbo.backupset bs
    JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
    WHERE bs.backup_finish_date >= DATEADD(day,-30,GETDATE())
)
SELECT
    database_name,
    MAX(CASE WHEN type='D' AND rn=1 THEN backup_finish_date END)  AS LastFull,
    MAX(CASE WHEN type='I' AND rn=1 THEN backup_finish_date END)  AS LastDiff,
    MAX(CASE WHEN type='L' AND rn=1 THEN backup_finish_date END)  AS LastLog,
    MAX(CASE WHEN type='D' AND rn=1 THEN physical_device_name END) AS LastFullPath,
    MAX(CASE WHEN type='L' AND rn=1 THEN physical_device_name END) AS LastLogPath
FROM lb
GROUP BY database_name
ORDER BY database_name;

PRINT '=== [7] LOG-BACKUP VOLUME / CADENCE (last 7d) ==='
SELECT
    bs.database_name,
    COUNT(*)                               AS LogBackups,
    SUM(bs.backup_size)/1024.0/1024        AS TotalMB,
    AVG(bs.backup_size)/1024.0/1024        AS AvgMB,
    MAX(bs.backup_size)/1024.0/1024        AS MaxMB,
    DATEDIFF(MINUTE, MIN(bs.backup_start_date), MAX(bs.backup_start_date))
        / NULLIF(COUNT(*)-1,0)             AS AvgMinBetween
FROM msdb.dbo.backupset bs
WHERE bs.type='L' AND bs.backup_finish_date >= DATEADD(day,-7,GETDATE())
GROUP BY bs.database_name
ORDER BY TotalMB DESC;

PRINT '=== [8] EXISTING BACKUP DESTINATIONS (last 7d) ==='
SELECT
    LEFT(bmf.physical_device_name, 120) AS device,
    bs.type, COUNT(*) AS n, MAX(bs.backup_finish_date) AS last_used
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.backup_finish_date >= DATEADD(day,-7,GETDATE())
GROUP BY LEFT(bmf.physical_device_name, 120), bs.type
ORDER BY last_used DESC;

PRINT '=== [9] EXISTING BACKUP JOBS ==='
SELECT j.name AS JobName, j.enabled, s.step_id, s.step_name, s.subsystem,
       LEFT(s.command, 300) AS CommandPreview
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
WHERE j.name LIKE '%backup%' OR s.command LIKE '%BACKUP %'
   OR s.command LIKE '%DatabaseBackup%' OR s.command LIKE '%sqlbackup%'
ORDER BY j.name, s.step_id;

PRINT '=== [10] TDE / ENCRYPTION ==='
SELECT DB_NAME(ek.database_id) AS DbName, ek.encryption_state, ek.encryptor_type,
       ek.key_algorithm, ek.key_length
FROM sys.dm_database_encryption_keys ek;

SELECT name, pvt_key_encryption_type_desc, expiry_date, thumbprint
FROM master.sys.certificates
WHERE pvt_key_encryption_type IS NOT NULL;

PRINT '=== [11] REPLICATION / CDC / CT / AG ==='
SELECT d.name, d.is_cdc_enabled, d.is_published, d.is_subscribed,
       d.is_merge_published, d.is_distributor,
       CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_databases c WHERE c.database_id=d.database_id)
            THEN 1 ELSE 0 END AS is_ct_enabled
FROM sys.databases d
WHERE d.database_id > 4;

SELECT name AS AgName FROM sys.availability_groups;

PRINT '=== [12] SPECIAL FEATURES PER DB ==='
IF OBJECT_ID('tempdb..#feat') IS NOT NULL DROP TABLE #feat;
CREATE TABLE #feat (DbName sysname, MemOptTables int, FileTables int, FilestreamFGs int);
DECLARE @s nvarchar(max)=N'';
SELECT @s = @s + N'
INSERT #feat SELECT N'''+REPLACE(d.name,'''','''''')+N''',
  (SELECT COUNT(*) FROM ['+d.name+N'].sys.tables WHERE is_memory_optimized=1),
  (SELECT COUNT(*) FROM ['+d.name+N'].sys.tables WHERE is_filetable=1),
  (SELECT COUNT(*) FROM ['+d.name+N'].sys.filegroups WHERE type=''FD'');'
FROM sys.databases d
WHERE d.database_id>4 AND d.state_desc='ONLINE';
EXEC sp_executesql @s;
SELECT * FROM #feat
WHERE MemOptTables>0 OR FileTables>0 OR FilestreamFGs>0
ORDER BY DbName;

PRINT '=== [13] VLF COUNT PER DB ==='
IF OBJECT_ID('tempdb..#vlf') IS NOT NULL DROP TABLE #vlf;
CREATE TABLE #vlf (DbName sysname, VlfCount int);
DECLARE @v nvarchar(max)=N'';
SELECT @v = @v + N'INSERT #vlf SELECT N'''+REPLACE(d.name,'''','''''')+N''',
  COUNT(*) FROM sys.dm_db_log_info('+CAST(d.database_id AS nvarchar(10))+N');'
FROM sys.databases d
WHERE d.database_id>4 AND d.state_desc='ONLINE';
EXEC sp_executesql @v;
SELECT * FROM #vlf ORDER BY VlfCount DESC;

PRINT '=== [14] LINKED SERVERS ==='
SELECT name, product, provider, data_source, catalog
FROM sys.servers WHERE server_id > 0;

PRINT '=== [15] LOGINS SUMMARY ==='
SELECT type_desc, COUNT(*) AS cnt
FROM sys.server_principals
WHERE type IN ('S','U','G') AND name NOT LIKE '##%' AND name NOT LIKE 'NT SERVICE\%'
GROUP BY type_desc;

PRINT '=== [16] DRIVE FREE SPACE ==='
SELECT DISTINCT vs.volume_mount_point, vs.file_system_type,
       vs.total_bytes/1024/1024/1024     AS TotalGB,
       vs.available_bytes/1024/1024/1024 AS AvailableGB
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs;
