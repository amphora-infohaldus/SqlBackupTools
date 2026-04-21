-- Phase 06 — enable the minute-LOG job after all initial FULLs succeed.
-- Only run this when you've verified CommandLog shows zero errors for today.

USE msdb;
SET NOCOUNT ON;

EXEC dbo.sp_update_job
    @job_name = N'DatabaseBackup - USER_DATABASES - LOG',
    @enabled  = 1;

PRINT 'LOG job enabled. First LOG backup fires on next schedule boundary.';
