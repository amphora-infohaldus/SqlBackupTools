SET NOCOUNT ON;

PRINT '=== [A] EDITION CONTEXT ==='
SELECT
    @@SERVERNAME AS ServerName,
    CAST(SERVERPROPERTY('Edition') AS varchar(64)) AS Edition,
    CAST(SERVERPROPERTY('EngineEdition') AS int) AS EngineEdition,
    CAST(SERVERPROPERTY('ProductVersion') AS varchar(32)) AS ProductVersion;

PRINT '=== [B] PER-DB PERSISTED ENTERPRISE FEATURES (the authoritative check) ==='
PRINT '--- Any row in this result = DB cannot be restored onto Standard/Web cleanly'
IF OBJECT_ID('tempdb..#esku') IS NOT NULL DROP TABLE #esku;
CREATE TABLE #esku (DbName sysname, FeatureName nvarchar(256));
DECLARE @sql nvarchar(max) = N'';
SELECT @sql = @sql + N'
BEGIN TRY
    INSERT #esku SELECT N'''+REPLACE(d.name,'''','''''')+N''', feature_name
    FROM ['+d.name+N'].sys.dm_db_persisted_sku_features;
END TRY BEGIN CATCH END CATCH;'
FROM sys.databases d
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE';
EXEC sp_executesql @sql;
SELECT DbName, FeatureName FROM #esku ORDER BY DbName, FeatureName;

PRINT '=== [C] TDE / DB-LEVEL ENCRYPTION ==='
SELECT DB_NAME(ek.database_id) AS DbName,
       ek.encryption_state,
       ek.encryptor_type
FROM sys.dm_database_encryption_keys ek
WHERE ek.database_id > 4;

PRINT '=== [D] RESOURCE GOVERNOR (user-defined pools/groups = Enterprise-only) ==='
SELECT 'Enabled' AS Setting, is_enabled FROM sys.resource_governor_configuration;
SELECT pool_id, name AS PoolName FROM sys.resource_governor_resource_pools WHERE pool_id > 2;
SELECT group_id, name AS GroupName, pool_id FROM sys.resource_governor_workload_groups WHERE group_id > 2;

PRINT '=== [E] SERVER AUDITS WITH PREDICATE FILTERS ==='
SELECT name, predicate
FROM sys.server_audits
WHERE predicate IS NOT NULL;

PRINT '=== [F] EXTERNAL SCRIPTS (R / Python in-DB) ==='
SELECT name, value, value_in_use
FROM sys.configurations
WHERE name LIKE '%external scripts%';

PRINT '=== [G] POLYBASE / EXTERNAL TABLES ==='
SELECT name, value, value_in_use
FROM sys.configurations
WHERE name LIKE '%polybase%';

IF OBJECT_ID('tempdb..#ext') IS NOT NULL DROP TABLE #ext;
CREATE TABLE #ext (DbName sysname, ExternalTables int, ExternalDataSources int);
DECLARE @sql2 nvarchar(max) = N'';
SELECT @sql2 = @sql2 + N'
BEGIN TRY
    INSERT #ext SELECT N'''+REPLACE(d.name,'''','''''')+N''',
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.external_tables),
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.external_data_sources);
END TRY BEGIN CATCH END CATCH;'
FROM sys.databases d
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE';
EXEC sp_executesql @sql2;
SELECT * FROM #ext WHERE ExternalTables > 0 OR ExternalDataSources > 0;

PRINT '=== [H] STRETCH DATABASE ==='
SELECT name, is_remote_data_archive_enabled
FROM sys.databases
WHERE is_remote_data_archive_enabled = 1;

PRINT '=== [I] ALWAYS ENCRYPTED WITH SECURE ENCLAVES ==='
SELECT name, value, value_in_use
FROM sys.configurations
WHERE name LIKE '%column encryption enclave%';

IF OBJECT_ID('tempdb..#aee') IS NOT NULL DROP TABLE #aee;
CREATE TABLE #aee (DbName sysname, ColumnMasterKeys int, EnclaveEnabledKeys int);
DECLARE @sql3 nvarchar(max) = N'';
SELECT @sql3 = @sql3 + N'
BEGIN TRY
    INSERT #aee SELECT N'''+REPLACE(d.name,'''','''''')+N''',
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.column_master_keys),
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.column_master_keys WHERE allow_enclave_computations = 1);
END TRY BEGIN CATCH END CATCH;'
FROM sys.databases d
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE';
EXEC sp_executesql @sql3;
SELECT * FROM #aee WHERE ColumnMasterKeys > 0 OR EnclaveEnabledKeys > 0;

PRINT '=== [J] IN-MEMORY OLTP USAGE (Web = 16 GB cap, Standard = 32 GB cap) ==='
IF OBJECT_ID('tempdb..#imoltp') IS NOT NULL DROP TABLE #imoltp;
CREATE TABLE #imoltp (DbName sysname, MemOptTables int, NativelyCompiledProcs int, MemOptFGs int);
DECLARE @sql4 nvarchar(max) = N'';
SELECT @sql4 = @sql4 + N'
BEGIN TRY
    INSERT #imoltp SELECT N'''+REPLACE(d.name,'''','''''')+N''',
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.tables WHERE is_memory_optimized = 1),
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.sql_modules WHERE uses_native_compilation = 1),
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.filegroups WHERE type = ''FX'');
END TRY BEGIN CATCH END CATCH;'
FROM sys.databases d
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE';
EXEC sp_executesql @sql4;
SELECT * FROM #imoltp WHERE MemOptTables > 0 OR NativelyCompiledProcs > 0 OR MemOptFGs > 0;

PRINT '=== [K] CLUSTERED COLUMNSTORE INDEXES (volume check — large CCI on Web can hurt) ==='
IF OBJECT_ID('tempdb..#cci') IS NOT NULL DROP TABLE #cci;
CREATE TABLE #cci (DbName sysname, CciCount int);
DECLARE @sql5 nvarchar(max) = N'';
SELECT @sql5 = @sql5 + N'
BEGIN TRY
    INSERT #cci SELECT N'''+REPLACE(d.name,'''','''''')+N''',
      (SELECT COUNT(*) FROM ['+d.name+N'].sys.indexes WHERE type = 5);
END TRY BEGIN CATCH END CATCH;'
FROM sys.databases d
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE';
EXEC sp_executesql @sql5;
SELECT * FROM #cci WHERE CciCount > 0;

PRINT '=== [L] VERDICT ==='
PRINT '-- If [B] is empty AND [C] is empty AND [D] shows only default pools/groups'
PRINT '-- AND [E]/[F]/[G] show no user config AND [H]/[I]/[J]/[K] empty,'
PRINT '-- then all DBs are safe to restore onto Web / Standard Edition.'
PRINT '-- Otherwise, each reported DB/feature must be remediated before Web migration.'
