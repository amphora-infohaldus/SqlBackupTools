-- Phase 03 — flip SIMPLE → FULL recovery on all user DBs, honoring exclusions.
--
-- Exclusion rules:
--   - Explicit names: AmphoraFT, AmphoraFT_13, wdimport_cache, wdimport_ekis,
--     amphora_logs (amphora_logs gets its own local-only FULL/DIFF jobs).
--   - Pattern: any DB whose name contains 'restored' or 'koolitus' stays
--     SIMPLE (training / ad-hoc restored copies — don't need DR).
--
-- Idempotent: DBs already in FULL are left alone; excluded DBs are skipped.
-- Fully-qualified sys.* names; safe from any DB context.

USE master;
SET NOCOUNT ON;

DECLARE @excluded TABLE (name sysname);
INSERT @excluded VALUES
    (N'AmphoraFT'),
    (N'AmphoraFT_13'),
    (N'wdimport_cache'),
    (N'wdimport_ekis'),
    (N'amphora_logs');

DECLARE @dbname sysname, @cmd nvarchar(max);
DECLARE @converted int = 0, @failed int = 0, @skippedExact int = 0, @skippedPattern int = 0;

DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT d.name
    FROM sys.databases d
    WHERE d.database_id > 4
      AND d.state_desc = 'ONLINE'
      AND d.recovery_model_desc = 'SIMPLE'
      AND NOT EXISTS (SELECT 1 FROM @excluded e WHERE e.name = d.name)
      AND d.name NOT LIKE N'%restored%'
      AND d.name NOT LIKE N'%koolitus%'
    ORDER BY d.name;

OPEN dbs;
FETCH NEXT FROM dbs INTO @dbname;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @cmd = N'ALTER DATABASE ' + QUOTENAME(@dbname) + N' SET RECOVERY FULL WITH NO_WAIT;';
    BEGIN TRY
        EXEC sp_executesql @cmd;
        PRINT N'[OK]   ' + @dbname;
        SET @converted += 1;
    END TRY
    BEGIN CATCH
        PRINT N'[FAIL] ' + @dbname + N' -- ' + ERROR_MESSAGE();
        SET @failed += 1;
    END CATCH
    FETCH NEXT FROM dbs INTO @dbname;
END
CLOSE dbs; DEALLOCATE dbs;

-- Counts
SELECT @skippedExact = COUNT(*)
FROM @excluded e
JOIN sys.databases d ON d.name = e.name
WHERE d.state_desc = 'ONLINE';

SELECT @skippedPattern = COUNT(*)
FROM sys.databases
WHERE database_id > 4
  AND state_desc = 'ONLINE'
  AND (name LIKE N'%restored%' OR name LIKE N'%koolitus%');

PRINT N'';
PRINT N'=== Summary ===';
PRINT N'Converted:                ' + CAST(@converted       AS nvarchar(8));
PRINT N'Failed:                   ' + CAST(@failed          AS nvarchar(8));
PRINT N'Skipped (exact exclude):  ' + CAST(@skippedExact    AS nvarchar(8));
PRINT N'Skipped (pattern match):  ' + CAST(@skippedPattern  AS nvarchar(8));

-- Final recovery-model breakdown
SELECT recovery_model_desc, COUNT(*) AS DbCount
FROM sys.databases
WHERE database_id > 4 AND state_desc = 'ONLINE'
GROUP BY recovery_model_desc
ORDER BY recovery_model_desc;
