# Daily DR health digest emailed to a fixed recipient.
# Reads: scheduled-task status, sys.databases, msdb.restorehistory, Get-Volume.
# Writes nothing locally; sends one HTML email via SMTP relay.
# Intended scheduled-task run on RESERV-2025 daily.

param(
    [string]$SmtpServer       = 'mail.datanet.ee',
    [int]$SmtpPort            = 25,
    [string]$MailFrom         = 'sqlbackup-dr@amphora.ee',
    [string[]]$MailTo         = @('ingmar@interinx.com'),
    [int]$RpoThresholdMin     = 60
)

$ErrorActionPreference = 'Stop'

function Get-SqlRows {
    param([string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection 'Server=.;Integrated Security=true;TrustServerCertificate=true'
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30
        $rdr = $cmd.ExecuteReader()
        $rows = New-Object System.Collections.ArrayList
        while ($rdr.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $rdr.FieldCount; $i++) {
                $val = $rdr.GetValue($i)
                $row[$rdr.GetName($i)] = if ($val -is [DBNull]) { $null } else { $val }
            }
            [void]$rows.Add([pscustomobject]$row)
        }
        $rdr.Close()
        return ,$rows
    } finally {
        $conn.Close()
    }
}

$hostname  = $env:COMPUTERNAME
$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')

# Scheduled-task health
$task = $null; $taskInfo = $null
try {
    $task = Get-ScheduledTask -TaskName 'SqlBackupTools-RestoreCycle' -ErrorAction Stop
    $taskInfo = Get-ScheduledTaskInfo -InputObject $task
} catch {}

# DB inventory
$dbInv = Get-SqlRows @"
SELECT COUNT(*) AS total,
       SUM(CASE WHEN state_desc='RESTORING' THEN 1 ELSE 0 END) AS restoring,
       SUM(CASE WHEN state_desc='ONLINE'    THEN 1 ELSE 0 END) AS online,
       SUM(CASE WHEN state_desc NOT IN ('RESTORING','ONLINE') THEN 1 ELSE 0 END) AS other
FROM sys.databases WHERE database_id > 4;
"@

# RPO outliers
$outliers = Get-SqlRows @"
SELECT destination_database_name AS db,
       DATEDIFF(MINUTE, MAX(restore_date), GETUTCDATE()) AS min_since
FROM msdb.dbo.restorehistory rh
JOIN sys.databases d ON d.name = rh.destination_database_name
WHERE d.database_id > 4
GROUP BY destination_database_name
HAVING DATEDIFF(MINUTE, MAX(restore_date), GETUTCDATE()) > $RpoThresholdMin
ORDER BY DATEDIFF(MINUTE, MAX(restore_date), GETUTCDATE()) DESC;
"@

# Recent restores
$recent = Get-SqlRows @"
SELECT TOP 5 destination_database_name AS db, MAX(restore_date) AS last_restore
FROM msdb.dbo.restorehistory rh
JOIN sys.databases d ON d.name = rh.destination_database_name
WHERE d.database_id > 4
GROUP BY destination_database_name
ORDER BY MAX(restore_date) DESC;
"@

# Disk
$disks = Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter |
    Select-Object DriveLetter,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
        @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB,1)}},
        @{n='FreePct';e={if ($_.Size) {[math]::Round(100*$_.SizeRemaining/$_.Size,1)} else {0}}}

# Status determination
$status = 'GREEN'; $statusColor = '#2e7d32'
if (-not $task -or $taskInfo.LastTaskResult -ne 0) {
    $status = 'RED'; $statusColor = '#c62828'
} elseif ($outliers.Count -gt 5) {
    $status = 'RED'; $statusColor = '#c62828'
} elseif ($outliers.Count -ge 1) {
    $status = 'AMBER'; $statusColor = '#f57c00'
}

# Build HTML
$css = @'
body { font-family: -apple-system, Segoe UI, sans-serif; font-size: 14px; color: #333; }
table { border-collapse: collapse; margin: 8px 0; }
th, td { border: 1px solid #ddd; padding: 4px 8px; text-align: left; vertical-align: top; }
th { background: #f5f5f5; }
.status { display: inline-block; padding: 4px 12px; color: white; font-weight: bold; border-radius: 4px; }
h1 { font-size: 18px; }
h2 { margin-top: 18px; font-size: 15px; }
.muted { color: #888; font-size: 11px; }
'@

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("<html><head><style>$css</style></head><body>")
[void]$sb.AppendLine("<h1>DR digest &mdash; $hostname &mdash; $timestamp</h1>")
[void]$sb.AppendLine("<p><span class='status' style='background:$statusColor'>$status</span></p>")

[void]$sb.AppendLine("<h2>Restore-cycle task</h2>")
if ($task) {
    [void]$sb.AppendLine("<table>")
    [void]$sb.AppendLine("<tr><th>State</th><td>$($task.State)</td></tr>")
    [void]$sb.AppendLine("<tr><th>Last run</th><td>$($taskInfo.LastRunTime)</td></tr>")
    [void]$sb.AppendLine("<tr><th>Last result</th><td>$($taskInfo.LastTaskResult)</td></tr>")
    [void]$sb.AppendLine("<tr><th>Next run</th><td>$($taskInfo.NextRunTime)</td></tr>")
    [void]$sb.AppendLine("</table>")
} else {
    [void]$sb.AppendLine("<p style='color:#c62828'>Task SqlBackupTools-RestoreCycle not found.</p>")
}

$d = $dbInv[0]
[void]$sb.AppendLine("<h2>Database inventory (user DBs, db_id &gt; 4)</h2>")
[void]$sb.AppendLine("<table><tr><th>Total</th><th>RESTORING</th><th>ONLINE</th><th>Other</th></tr>")
[void]$sb.AppendLine("<tr><td>$($d.total)</td><td>$($d.restoring)</td><td>$($d.online)</td><td>$($d.other)</td></tr></table>")

[void]$sb.AppendLine("<h2>RPO outliers (last restore &gt; $RpoThresholdMin min ago)</h2>")
if ($outliers.Count -eq 0) {
    [void]$sb.AppendLine("<p>None.</p>")
} else {
    [void]$sb.AppendLine("<table><tr><th>Database</th><th>Min since last restore</th></tr>")
    foreach ($o in $outliers) {
        [void]$sb.AppendLine("<tr><td>$($o.db)</td><td>$($o.min_since)</td></tr>")
    }
    [void]$sb.AppendLine("</table>")
}

[void]$sb.AppendLine("<h2>Latest 5 restores (UTC)</h2>")
[void]$sb.AppendLine("<table><tr><th>Database</th><th>Last restore</th></tr>")
foreach ($r in $recent) {
    [void]$sb.AppendLine("<tr><td>$($r.db)</td><td>$($r.last_restore)</td></tr>")
}
[void]$sb.AppendLine("</table>")

[void]$sb.AppendLine("<h2>Disk</h2><table><tr><th>Drive</th><th>Size GB</th><th>Free GB</th><th>Free %</th></tr>")
foreach ($dk in $disks) {
    [void]$sb.AppendLine("<tr><td>$($dk.DriveLetter)</td><td>$($dk.SizeGB)</td><td>$($dk.FreeGB)</td><td>$($dk.FreePct)</td></tr>")
}
[void]$sb.AppendLine("</table>")

[void]$sb.AppendLine("<p class='muted'>Sent by dr-digest.ps1 on $hostname at $timestamp.</p>")
[void]$sb.AppendLine("</body></html>")

$html    = $sb.ToString()
$subject = "DR digest [$status] - $hostname - $timestamp"

Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort `
    -From $MailFrom -To $MailTo -Subject $subject -Body $html -BodyAsHtml
