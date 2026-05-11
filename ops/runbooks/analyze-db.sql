-- Per-table sizing + first/last-row dating for any DB.
-- Defaults to AmphoraBackend; change the `USE` and re-run for other DBs.
--
-- For each table:
--   row_count            -- from sys.dm_db_partition_stats (data partition)
--   total_mb / data_mb / index_mb  -- reserved pages, data = heap/clustered, index = NC
--   ts_column            -- best-named datetime/datetime2/datetimeoffset/smalldatetime
--                           column (priority: %created% > %inserted% > %logged% > ...)
--   first_row / last_row -- MIN/MAX of ts_column
--   span_days            -- DATEDIFF(day, first_row, last_row)
--
-- Tables with no datetime column show NULL ts/first/last.

USE AmphoraBackend;
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#tbl') IS NOT NULL DROP TABLE #tbl;
-- Force temp columns to the source-DB collation so comparisons against
-- sys.* catalog views don't trip "Cannot resolve collation conflict"
-- when tempdb's collation differs from this DB's.
CREATE TABLE #tbl (
    schema_name sysname COLLATE DATABASE_DEFAULT,
    table_name  sysname COLLATE DATABASE_DEFAULT,
    row_count   bigint,
    data_kb     bigint,
    index_kb    bigint,
    total_kb    bigint,
    ts_column   sysname COLLATE DATABASE_DEFAULT NULL,
    first_row   datetime2 NULL,
    last_row    datetime2 NULL
);

-- 1) size + row count from sys.dm_db_partition_stats (no multi-row join, clean SUMs)
INSERT #tbl (schema_name, table_name, row_count, data_kb, index_kb, total_kb)
SELECT
    s.name,
    t.name,
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count            ELSE 0 END),
    SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.reserved_page_count  ELSE 0 END) * 8,
    SUM(CASE WHEN ps.index_id >= 2     THEN ps.reserved_page_count  ELSE 0 END) * 8,
    SUM(ps.reserved_page_count) * 8
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name;

-- 2) for each table, find best datetime column + min/max
DECLARE @schema sysname, @table sysname, @col sysname, @sql nvarchar(max);
DECLARE @minTs datetime2, @maxTs datetime2;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        t.schema_name,
        t.table_name,
        (SELECT TOP 1 c.name
         FROM   sys.columns c
         JOIN   sys.tables  tt ON tt.object_id  = c.object_id
         JOIN   sys.schemas ss ON ss.schema_id  = tt.schema_id
         WHERE  ss.name = t.schema_name COLLATE DATABASE_DEFAULT
           AND  tt.name = t.table_name  COLLATE DATABASE_DEFAULT
           AND  c.user_type_id IN (TYPE_ID('datetime'),     TYPE_ID('datetime2'),
                                   TYPE_ID('datetimeoffset'),TYPE_ID('smalldatetime'))
         ORDER BY CASE
             WHEN c.name LIKE N'%created%'   COLLATE DATABASE_DEFAULT THEN 1
             WHEN c.name LIKE N'%inserted%'  COLLATE DATABASE_DEFAULT THEN 2
             WHEN c.name LIKE N'%logged%'    COLLATE DATABASE_DEFAULT THEN 3
             WHEN c.name LIKE N'%sent%'      COLLATE DATABASE_DEFAULT THEN 4
             WHEN c.name LIKE N'%added%'     COLLATE DATABASE_DEFAULT THEN 5
             WHEN c.name LIKE N'%timestamp%' COLLATE DATABASE_DEFAULT THEN 6
             WHEN c.name LIKE N'%date%'      COLLATE DATABASE_DEFAULT THEN 7
             WHEN c.name LIKE N'%time%'      COLLATE DATABASE_DEFAULT THEN 8
             ELSE 99
         END, c.column_id)
    FROM #tbl t;

OPEN c;
FETCH NEXT FROM c INTO @schema, @table, @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @minTs = NULL; SET @maxTs = NULL;
    IF @col IS NOT NULL
    BEGIN
        SET @sql = N'SELECT @mn = MIN(' + QUOTENAME(@col)
                 + N'), @mx = MAX(' + QUOTENAME(@col)
                 + N') FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table)
                 + N' WITH (NOLOCK);';
        BEGIN TRY
            EXEC sp_executesql @sql,
                 N'@mn datetime2 OUTPUT, @mx datetime2 OUTPUT',
                 @mn = @minTs OUTPUT, @mx = @maxTs OUTPUT;
        END TRY
        BEGIN CATCH
            SET @minTs = NULL; SET @maxTs = NULL;
        END CATCH
    END

    UPDATE #tbl
       SET ts_column = @col, first_row = @minTs, last_row = @maxTs
     WHERE schema_name = @schema AND table_name = @table;

    FETCH NEXT FROM c INTO @schema, @table, @col;
END
CLOSE c; DEALLOCATE c;

-- 3) per-table report
SELECT
    schema_name + '.' + table_name AS [table],
    row_count,
    CAST(total_kb / 1024.0 AS decimal(12,1)) AS total_mb,
    CAST(data_kb  / 1024.0 AS decimal(12,1)) AS data_mb,
    CAST(index_kb / 1024.0 AS decimal(12,1)) AS index_mb,
    ts_column,
    first_row,
    last_row,
    CASE WHEN first_row IS NOT NULL AND last_row IS NOT NULL
         THEN DATEDIFF(DAY, first_row, last_row) END AS span_days
FROM #tbl
ORDER BY total_kb DESC;

-- 4) database-level summary
SELECT
    COUNT(*)              AS table_count,
    SUM(row_count)        AS total_rows,
    CAST(SUM(total_kb) / 1024.0 AS decimal(14,1)) AS total_mb,
    (SELECT CAST(SUM(size) * 8 / 1024.0 AS decimal(14,1))
       FROM sys.database_files WHERE type_desc = 'ROWS') AS data_file_mb,
    (SELECT CAST(SUM(size) * 8 / 1024.0 AS decimal(14,1))
       FROM sys.database_files WHERE type_desc = 'LOG')  AS log_file_mb
FROM #tbl;
