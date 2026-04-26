# Restore amphorafw_infohaldus to a development clone (baseline or dev).
#
# - baseline: READ_ONLY, comparison reference. Refresh whenever you want a
#   newer "before" snapshot to diff against.
# - dev:      read-write, target where the finances bot adds invoices.
#
# Re-runnable: drops the named clone if it already exists, then restores
# from -BackupPath (or the most recent .bak in -BackupRoot).
#
# This DB has no LOG backups on the primary (ops/runbooks/why-simple-recovery.sql
# investigates why), so the clone's freshness is bounded by the latest FULL
# (Ola FULL job runs daily on the primaries).
#
# Usage on RESERV-2025 (backup folder is local):
#   .\restore-infohaldus-clone.ps1 -Target baseline
#
# Usage on a workstation (.bak copied locally):
#   .\restore-infohaldus-clone.ps1 -Target dev `
#       -BackupPath C:\BackupSource\PREMIUM-2022_amphorafw_infohaldus_FULL_20260426_041105.bak

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('baseline', 'dev')]
    [string]$Target,

    # Explicit .bak file. If omitted, the script picks the newest .bak in $BackupRoot.
    [string]$BackupPath,

    # Folder scanned when -BackupPath isn't given. Default matches the
    # claude-coder-w11 workstation layout where .bak files are scp'd to
    # C:\BackupSource\ from RESERV-2025. On RESERV itself, pass
    # -BackupRoot C:\SqlBackup\PREMIUM-2022\amphorafw_infohaldus\FULL.
    [string]$BackupRoot = 'C:\BackupSource',

    # Where the restored .mdf/.ldf land. Created if missing.
    [string]$DataDir = 'C:\Data\dev',

    # SQL Server instance to restore into. '.' = local default instance.
    [string]$ServerInstance = '.'
)

$ErrorActionPreference = 'Stop'

$source    = 'amphorafw_infohaldus'
$cloneName = "${source}_${Target}"

if ($BackupPath) {
    $latestBak = Get-Item -Path $BackupPath
} else {
    $latestBak = Get-ChildItem -Path $BackupRoot -Filter '*.bak' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latestBak) {
        throw "No .bak files found in $BackupRoot"
    }
}

Write-Host "Server        : $ServerInstance"
Write-Host "Source backup : $($latestBak.FullName)"
Write-Host "                $([math]::Round($latestBak.Length/1MB,1)) MB, taken $($latestBak.LastWriteTime)"
Write-Host "Target DB     : $cloneName ($Target)"
Write-Host "Data dir      : $DataDir"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Discover logical file names from the backup so the MOVE clauses are correct.
$connStr = "Server=$ServerInstance;Integrated Security=true;TrustServerCertificate=true"
$conn = New-Object System.Data.SqlClient.SqlConnection $connStr
$conn.Open()
try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "RESTORE FILELISTONLY FROM DISK = N'$($latestBak.FullName)'"
    $cmd.CommandTimeout = 120
    $reader = $cmd.ExecuteReader()
    $dataLogical = $null
    $logLogical = $null
    while ($reader.Read()) {
        $name = $reader['LogicalName']
        $type = $reader['Type']
        if ($type -eq 'D' -and -not $dataLogical) { $dataLogical = $name }
        if ($type -eq 'L' -and -not $logLogical)  { $logLogical  = $name }
    }
    $reader.Close()
} finally {
    $conn.Close()
}
if (-not $dataLogical -or -not $logLogical) {
    throw "Could not determine logical file names from $($latestBak.FullName)"
}
Write-Host "Logical names : data=$dataLogical, log=$logLogical"

$mdf = Join-Path $DataDir "$cloneName.mdf"
$ldf = Join-Path $DataDir "${cloneName}_log.ldf"

$sql = @"
USE master;
SET XACT_ABORT ON;

IF DB_ID(N'$cloneName') IS NOT NULL
BEGIN
    PRINT 'Dropping existing [$cloneName]';
    ALTER DATABASE [$cloneName] SET READ_WRITE WITH ROLLBACK IMMEDIATE;
    ALTER DATABASE [$cloneName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$cloneName];
END

PRINT 'Restoring [$cloneName] from $($latestBak.FullName)';
RESTORE DATABASE [$cloneName]
    FROM DISK = N'$($latestBak.FullName)'
    WITH MOVE N'$dataLogical' TO N'$mdf',
         MOVE N'$logLogical'  TO N'$ldf',
         RECOVERY,
         REPLACE,
         STATS = 5;
"@

if ($Target -eq 'baseline') {
    $sql += @"

PRINT 'Setting [$cloneName] READ_ONLY';
ALTER DATABASE [$cloneName] SET READ_ONLY WITH ROLLBACK IMMEDIATE;
"@
}

$sql += @"

SELECT name, state_desc, recovery_model_desc, is_read_only,
       (SELECT TOP 1 physical_name FROM sys.master_files WHERE database_id = DB_ID(N'$cloneName') AND type = 0) AS data_file
FROM sys.databases
WHERE name = N'$cloneName';
"@

$tempSql = New-TemporaryFile
try {
    Set-Content -Path $tempSql.FullName -Value $sql -Encoding ASCII
    & sqlcmd -S $ServerInstance -E -b -i $tempSql.FullName
    $exit = $LASTEXITCODE
} finally {
    Remove-Item -Path $tempSql.FullName -Force -ErrorAction SilentlyContinue
}
if ($exit -ne 0) {
    throw "sqlcmd exited with code $exit"
}

Write-Host "Done. [$cloneName] ready."
