# Restore an Amphora tenant DB as a local clone on a workstation (or RESERV).
#
# Three target modes:
#
# - baseline: clone named "<source>_baseline", set READ_ONLY. Comparison
#   reference for dev workflows where you want a "before" snapshot to diff
#   against.
# - dev:      clone named "<source>_dev", read-write. The bot under
#   development inserts/migrates here.
# - readonly: clone named exactly "<source>", set READ_ONLY. For loading
#   other tenant DBs locally to read from (no dev counterpart).
#
# Re-runnable: drops the named clone if it already exists, then restores
# from -BackupPath (or the most recent matching .bak in -BackupRoot).
#
# Source DBs at Amphora are FULL recovery, but Ola's LOG-backup job is
# excluded for amphorafw_infohaldus (no LOG/ subfolder ships) and may be
# excluded for others -- clone freshness is bounded by the latest FULL.
#
# Usage examples (claude-coder-w11 workstation, .bak files scp'd from RESERV):
#
#   # Finances-bot dev pair on amphorafw_infohaldus:
#   .\restore-clone.ps1 -Target baseline
#   .\restore-clone.ps1 -Target dev
#
#   # Other tenants as plain READ_ONLY:
#   .\restore-clone.ps1 -SourceDb amphorafw_hiiumaavv  -Target readonly
#   .\restore-clone.ps1 -SourceDb amphorafw_haapsalulv -Target readonly
#
#   # Explicit .bak path:
#   .\restore-clone.ps1 -SourceDb amphorafw_hiiumaavv -Target readonly `
#       -BackupPath C:\BackupSource\SQL-2022_amphorafw_hiiumaavv_FULL_20260503_022759.bak

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('baseline', 'dev', 'readonly')]
    [string]$Target,

    # Source database name (e.g. amphorafw_infohaldus, amphorafw_hiiumaavv).
    # When -BackupPath is omitted, the auto-pick scans -BackupRoot for the
    # newest .bak whose filename contains this string.
    [string]$SourceDb = 'amphorafw_infohaldus',

    # Explicit .bak file. If omitted, the script picks the newest
    # .bak in $BackupRoot whose name contains $SourceDb.
    [string]$BackupPath,

    # Folder scanned when -BackupPath isn't given. Default matches the
    # claude-coder-w11 workstation layout where .bak files are scp'd to
    # C:\BackupSource\ from RESERV-2025. On RESERV itself, pass
    # -BackupRoot C:\SqlBackup\<primary>\<source>\FULL.
    [string]$BackupRoot = 'C:\BackupSource',

    # Where the restored .mdf/.ldf land. Created if missing.
    [string]$DataDir = 'C:\Data\dev',

    # SQL Server instance to restore into. '.' = local default instance.
    [string]$ServerInstance = '.'
)

$ErrorActionPreference = 'Stop'

$source = $SourceDb
$cloneName = if ($Target -eq 'readonly') { $source } else { "${source}_${Target}" }
$setReadOnly = ($Target -eq 'baseline' -or $Target -eq 'readonly')

if ($BackupPath) {
    $latestBak = Get-Item -Path $BackupPath
} else {
    $latestBak = Get-ChildItem -Path $BackupRoot -Filter "*$source*.bak" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latestBak) {
        throw "No .bak files matching '*$source*.bak' found in $BackupRoot"
    }
}

Write-Host "Server        : $ServerInstance"
Write-Host "Source DB     : $source"
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

if ($setReadOnly) {
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
