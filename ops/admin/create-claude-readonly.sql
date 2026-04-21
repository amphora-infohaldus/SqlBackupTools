-- =============================================================
-- Read-only monitoring login: [claude]
-- =============================================================
-- Grants:
--   * Server-level:  VIEW SERVER STATE, VIEW ANY DEFINITION,
--                    VIEW ANY DATABASE, CONNECT ANY DATABASE
--   * msdb:          db_datareader + SQLAgentReaderRole
--                    (backup history, job history — read-only)
--   * Every user DB: VIEW DATABASE STATE + VIEW DEFINITION
--                    (DMVs + metadata only; NO table data access)
--
-- Explicitly does NOT grant:
--   * db_datareader on user DBs  (cannot read actual table data)
--   * Any write / ALTER / CONTROL / EXECUTE
--   * sysadmin / securityadmin / dbcreator
--
-- Idempotent — safe to run multiple times.
-- Run as sysadmin (sa or equivalent).
-- Works in SSMS (normal mode) and sqlcmd.
-- Collation-safe: survives mixed server / DB / variable collations.
-- =============================================================

USE [master];          -- MUST be first so variables inherit master's collation
SET NOCOUNT ON;

-- -------------------------------------------------------------
-- *** EDIT THIS PASSWORD BEFORE RUNNING ***
-- Must pass Windows password policy: >=8 chars, upper+lower+digit+special
-- -------------------------------------------------------------
DECLARE @ClaudePw NVARCHAR(128) = N'ChangeMe-To-A-Strong-Password-123!';

-- ------- Server-level login -------
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'claude')
BEGIN
    DECLARE @sql NVARCHAR(MAX) =
        N'CREATE LOGIN [claude] WITH PASSWORD = N'''
      + REPLACE(@ClaudePw COLLATE DATABASE_DEFAULT, N'''', N'''''')
      + N''', DEFAULT_DATABASE = [master], CHECK_POLICY = ON;';
    EXEC sp_executesql @sql;
    PRINT 'Created login [claude].';
END
ELSE
    PRINT 'Login [claude] already exists — skipping CREATE.';

-- ------- Server-level permissions (read-only monitoring) -------
GRANT VIEW SERVER STATE      TO [claude];
GRANT VIEW ANY DEFINITION    TO [claude];
GRANT VIEW ANY DATABASE      TO [claude];
GRANT CONNECT ANY DATABASE   TO [claude];

-- Belt-and-braces: explicitly deny dangerous server-level rights
DENY ALTER ANY LOGIN         TO [claude];
DENY ALTER ANY SERVER AUDIT  TO [claude];
DENY SHUTDOWN                TO [claude];
DENY ALTER SETTINGS          TO [claude];
GO

-- ------- msdb: backup + job history readable -------
USE [msdb];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'claude')
    CREATE USER [claude] FOR LOGIN [claude];

ALTER ROLE db_datareader      ADD MEMBER [claude];
ALTER ROLE SQLAgentReaderRole ADD MEMBER [claude];
GO

-- ------- Per-DB: DMVs + metadata (NO table data) -------
USE [master];
GO

DECLARE @dbname SYSNAME, @cmd NVARCHAR(MAX);

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE (database_id > 4 OR name = 'model')
      AND state_desc = 'ONLINE'
      AND is_read_only = 0;

OPEN dbs;
FETCH NEXT FROM dbs INTO @dbname;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cmd = N'USE ' + QUOTENAME(@dbname COLLATE DATABASE_DEFAULT) + N';
        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''claude'')
            CREATE USER [claude] FOR LOGIN [claude];
        GRANT VIEW DATABASE STATE TO [claude];
        GRANT VIEW DEFINITION     TO [claude];';
    BEGIN TRY
        EXEC sp_executesql @cmd;
    END TRY
    BEGIN CATCH
        PRINT N'Skipped DB [' + (@dbname COLLATE DATABASE_DEFAULT) + N']: '
            + CAST(ERROR_MESSAGE() AS NVARCHAR(2048));
    END CATCH
    FETCH NEXT FROM dbs INTO @dbname;
END
CLOSE dbs;
DEALLOCATE dbs;
GO

-- ============================================================
-- VERIFICATION
-- ============================================================
USE [master];
GO
SET NOCOUNT ON;

PRINT '=== VERIFICATION ===';

SELECT 'ServerLogin' AS Scope, name, type_desc, is_disabled, create_date
FROM sys.server_principals WHERE name = 'claude';

SELECT 'ServerPermissions' AS Scope, pe.permission_name, pe.state_desc
FROM sys.server_principals p
JOIN sys.server_permissions pe ON pe.grantee_principal_id = p.principal_id
WHERE p.name = 'claude'
ORDER BY pe.state_desc, pe.permission_name;

DECLARE @cnt INT = 0, @total INT = 0, @dbn SYSNAME, @has INT;
DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE' AND (database_id > 4 OR name = 'model');
OPEN c2;
FETCH NEXT FROM c2 INTO @dbn;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @total += 1;
    DECLARE @q NVARCHAR(MAX) = N'SELECT @out = COUNT(*) FROM '
        + QUOTENAME(@dbn COLLATE DATABASE_DEFAULT)
        + N'.sys.database_principals WHERE name = N''claude'';';
    EXEC sp_executesql @q, N'@out INT OUTPUT', @out = @has OUTPUT;
    IF @has > 0 SET @cnt += 1;
    FETCH NEXT FROM c2 INTO @dbn;
END
CLOSE c2;
DEALLOCATE c2;

PRINT N'[claude] user present in ' + CAST(@cnt AS NVARCHAR(16)) + N' of '
    + CAST(@total AS NVARCHAR(16)) + N' online user DBs (+model).';
