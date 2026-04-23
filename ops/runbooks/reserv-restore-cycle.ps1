# Continuous-restore wrapper for RESERV-2025.
# Sweeps both primary folders in sequence; exits non-zero if either returns
# a non-zero code. Invoked by the SqlBackupTools-RestoreCycle Scheduled Task.

$ErrorActionPreference = 'Stop'
$exe = 'C:\SqlBackupTools\SqlBackupTools.exe'
$folders = @(
    'C:\SqlBackup\PREMIUM-2022',
    'C:\SqlBackup\SQL-2022'
)

$commonArgs = @(
    'restore',
    '-h', '.',
    '--continueLogs',
    '--ignoreDatabases', 'amphora_logs',
    '--logs', 'C:\SqlBackupTools\logs'
)

$overallExit = 0
foreach ($f in $folders) {
    Write-Host "[$([DateTime]::UtcNow.ToString('o'))] Sweeping $f"
    & $exe @commonArgs --folder $f
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Warning "[$f] exited with code $code"
        $overallExit = $code
    }
}

exit $overallExit
