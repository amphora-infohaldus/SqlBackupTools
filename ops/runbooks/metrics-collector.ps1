# Emits Prometheus textfile metrics for the SqlBackupTools continuous-restore
# daemon on RESERV. Alloy's windows_exporter textfile collector reads the
# output directory (see ops/alloy/config.alloy) and forwards to prod Mimir.
#
# Scheduled as its own Windows task, every 1 min. Safe to run concurrently
# with the restore cycle -- read-only SQL queries + filesystem scans only.

$ErrorActionPreference = 'Stop'

$metricsDir = 'C:\SqlBackupTools\metrics'
$outFile    = Join-Path $metricsDir 'sqlbackup.prom'
$tmpFile    = "$outFile.$PID.tmp"
$shipRoot   = 'C:\SqlBackup'
$primaries  = @('PREMIUM-2022', 'SQL-2022')

New-Item -ItemType Directory -Force -Path $metricsDir | Out-Null

$sb = [System.Text.StringBuilder]::new()
$nowUtc = [DateTime]::UtcNow

function Add-MetricBlock([string]$metricName, [string]$help, [string]$type, [scriptblock]$emit) {
    [void]$sb.AppendLine("# HELP $metricName $help")
    [void]$sb.AppendLine("# TYPE $metricName $type")
    & $emit
    [void]$sb.AppendLine("")
}

# --- Scheduled task health -------------------------------------------------
$t = Get-ScheduledTaskInfo -TaskName 'SqlBackupTools-RestoreCycle' -ErrorAction SilentlyContinue
if ($t) {
    Add-MetricBlock 'sqlbackup_task_last_exit_code' 'Exit code of the most recent restore cycle (0 = success)' 'gauge' {
        [void]$sb.AppendLine("sqlbackup_task_last_exit_code $($t.LastTaskResult)")
    }
    Add-MetricBlock 'sqlbackup_task_last_run_timestamp_seconds' 'Unix timestamp of the most recent restore cycle start' 'gauge' {
        $ts = 0
        if ($t.LastRunTime -and $t.LastRunTime.Year -ge 2026) {
            $ts = [DateTimeOffset]::new($t.LastRunTime.ToUniversalTime()).ToUnixTimeSeconds()
        }
        [void]$sb.AppendLine("sqlbackup_task_last_run_timestamp_seconds $ts")
    }
    Add-MetricBlock 'sqlbackup_task_missed_runs' 'Number of missed scheduled runs' 'gauge' {
        [void]$sb.AppendLine("sqlbackup_task_missed_runs $($t.NumberOfMissedRuns)")
    }
}

# --- Disk free on C: -------------------------------------------------------
$drive = Get-PSDrive C
Add-MetricBlock 'sqlbackup_disk_free_bytes' 'Free bytes on C: (where SqlBackup lives)' 'gauge' {
    [void]$sb.AppendLine("sqlbackup_disk_free_bytes $($drive.Free)")
}
Add-MetricBlock 'sqlbackup_disk_used_bytes' 'Used bytes on C:' 'gauge' {
    [void]$sb.AppendLine("sqlbackup_disk_used_bytes $($drive.Used)")
}

# --- DB state + RPO (from msdb.restorehistory) -----------------------------
$conn = New-Object System.Data.SqlClient.SqlConnection 'Server=.;Database=master;Integrated Security=true;Encrypt=false;'
$conn.Open()
try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
SET NOCOUNT ON;
SELECT
    d.name                                   AS db_name,
    d.state_desc                             AS db_state,
    DATEDIFF(SECOND, COALESCE(rh.last_any, '1900-01-01'), GETUTCDATE()) AS rpo_seconds,
    CASE WHEN rh.last_log IS NULL THEN 0 ELSE 1 END AS has_log_restore
FROM sys.databases d
LEFT JOIN (
    SELECT destination_database_name,
           MAX(CASE WHEN restore_type='L' THEN restore_date END) AS last_log,
           MAX(restore_date)                                     AS last_any
    FROM msdb.dbo.restorehistory
    GROUP BY destination_database_name
) rh ON d.name = rh.destination_database_name
WHERE d.database_id > 4
"@
    $reader = $cmd.ExecuteReader()

    [void]$sb.AppendLine("# HELP sqlbackup_db_state Database state -- value is 1 for the active state")
    [void]$sb.AppendLine("# TYPE sqlbackup_db_state gauge")
    $stateLines = [System.Collections.Generic.List[string]]::new()
    $rpoLines   = [System.Collections.Generic.List[string]]::new()
    $missingLogLines = [System.Collections.Generic.List[string]]::new()
    while ($reader.Read()) {
        $name   = ([string]$reader['db_name']).Replace('\', '\\').Replace('"', '\"')
        $state  = [string]$reader['db_state']
        $rpo    = [int]$reader['rpo_seconds']
        $hasLog = [int]$reader['has_log_restore']
        $stateLines.Add("sqlbackup_db_state{db_name=""$name"",state=""$state""} 1")
        $rpoLines.Add("sqlbackup_rpo_seconds{db_name=""$name""} $rpo")
        if (-not $hasLog) {
            $missingLogLines.Add("sqlbackup_db_missing_log_restore{db_name=""$name""} 1")
        }
    }
    $reader.Close()
    $stateLines | ForEach-Object { [void]$sb.AppendLine($_) }
    [void]$sb.AppendLine("")

    [void]$sb.AppendLine("# HELP sqlbackup_rpo_seconds Seconds since most-recent restore per DB (any type)")
    [void]$sb.AppendLine("# TYPE sqlbackup_rpo_seconds gauge")
    $rpoLines | ForEach-Object { [void]$sb.AppendLine($_) }
    [void]$sb.AppendLine("")

    if ($missingLogLines.Count -gt 0) {
        [void]$sb.AppendLine("# HELP sqlbackup_db_missing_log_restore 1 when a DB has a FULL on RESERV but no LOG restore yet")
        [void]$sb.AppendLine("# TYPE sqlbackup_db_missing_log_restore gauge")
        $missingLogLines | ForEach-Object { [void]$sb.AppendLine($_) }
        [void]$sb.AppendLine("")
    }
}
finally {
    $conn.Close()
    $conn.Dispose()
}

# --- Ship-folder freshness per (primary, db) -------------------------------
[void]$sb.AppendLine("# HELP sqlbackup_ship_newest_trn_age_seconds Age of newest .trn file per DB on RESERV")
[void]$sb.AppendLine("# TYPE sqlbackup_ship_newest_trn_age_seconds gauge")
[void]$sb.AppendLine("# HELP sqlbackup_ship_has_bak 1 if at least one .bak is present for the DB on RESERV")
[void]$sb.AppendLine("# TYPE sqlbackup_ship_has_bak gauge")

$hasBakLines = [System.Collections.Generic.List[string]]::new()
$trnAgeLines = [System.Collections.Generic.List[string]]::new()

foreach ($primary in $primaries) {
    $root = Join-Path $shipRoot $primary
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dbName = $_.Name.Replace('"', '\"')
        $logDir = Join-Path $_.FullName 'LOG'
        $fullDir = Join-Path $_.FullName 'FULL'

        if (Test-Path $logDir) {
            $newest = Get-ChildItem $logDir -Filter '*.trn' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newest) {
                $age = [int]($nowUtc - $newest.LastWriteTimeUtc).TotalSeconds
                $trnAgeLines.Add("sqlbackup_ship_newest_trn_age_seconds{db_name=""$dbName"",primary=""$primary""} $age")
            }
        }

        $hasBak = 0
        if ((Test-Path $fullDir) -and (Get-ChildItem $fullDir -Filter '*.bak' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $hasBak = 1
        }
        $hasBakLines.Add("sqlbackup_ship_has_bak{db_name=""$dbName"",primary=""$primary""} $hasBak")
    }
}
$trnAgeLines | ForEach-Object { [void]$sb.AppendLine($_) }
[void]$sb.AppendLine("")
$hasBakLines | ForEach-Object { [void]$sb.AppendLine($_) }
[void]$sb.AppendLine("")

# --- Total staged .trn (disk pressure signal) ------------------------------
Add-MetricBlock 'sqlbackup_staged_trn_count' 'Count of .trn files under C:\SqlBackup (all primaries)' 'gauge' {
    $n = (Get-ChildItem $shipRoot -Recurse -Filter '*.trn' -ErrorAction SilentlyContinue | Measure-Object).Count
    [void]$sb.AppendLine("sqlbackup_staged_trn_count $n")
}

Add-MetricBlock 'sqlbackup_staged_trn_bytes' 'Total size of .trn files under C:\SqlBackup' 'gauge' {
    $b = (Get-ChildItem $shipRoot -Recurse -Filter '*.trn' -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $b) { $b = 0 }
    [void]$sb.AppendLine("sqlbackup_staged_trn_bytes $b")
}

# --- Final: emit our own heartbeat ----------------------------------------
Add-MetricBlock 'sqlbackup_metrics_collector_timestamp_seconds' 'Unix timestamp of the last successful metrics-collector run' 'gauge' {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [void]$sb.AppendLine("sqlbackup_metrics_collector_timestamp_seconds $ts")
}

# Atomic write -- emitter must never be caught with a half-written *.prom.
$sb.ToString() | Out-File -Encoding ascii -FilePath $tmpFile
Move-Item -Force $tmpFile $outFile
