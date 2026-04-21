-- Phase 06 — kick off the initial FULL on this primary.
-- Runs the job async; monitor CommandLog for progress.

USE msdb;
SET NOCOUNT ON;

EXEC dbo.sp_start_job @job_name = N'DatabaseBackup - USER_DATABASES - FULL';
PRINT 'FULL job started. Check master.dbo.CommandLog for progress.';

-- Helpful monitor query:
-- SELECT TOP 20 DatabaseName, CommandType, StartTime, EndTime,
--        DATEDIFF(SECOND, StartTime, ISNULL(EndTime, GETDATE())) AS SecondsElapsed,
--        ErrorNumber, LEFT(ErrorMessage, 200) AS Err
-- FROM master.dbo.CommandLog
-- ORDER BY ID DESC;
