# Continuous-restore wrapper for RESERV-2025.
# Sweeps both primary folders in sequence; exits non-zero if either returns
# a non-zero code. Invoked by the SqlBackupTools-RestoreCycle Scheduled Task.

$ErrorActionPreference = 'Stop'
$exe = 'C:\SqlBackupTools\SqlBackupTools.exe'
$logDir = 'C:\SqlBackupTools\logs'
# The exe's Serilog config checks DirectoryInfo.Exists before using --logs.
# If the folder is missing it falls back to CWD-relative 'logs/', which under
# SYSTEM lands in C:\Windows\System32\logs\. mkdir here is idempotent.
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$folders = @(
    'C:\SqlBackup\PREMIUM-2022',
    'C:\SqlBackup\SQL-2022'
)

$commonArgs = @(
    'restore',
    '-h', '.',
    '--continueLogs',
    # amphora_logs       -- excluded from ship by design; only shipped from PREMIUM-2022
    #                       and we never apply it on RESERV (separate local jobs handle it).
    # amphora_logs_13    -- known stale since 2026-04-21; ship from PREMIUM-2022 hits a name
    #                       collision / chain-break we haven't unwound. Skipped to keep the
    #                       daemon from re-trying every cycle. Drop the local DB on RESERV
    #                       once we're sure we don't need the 20-day-old snapshot.
    '--ignoreDatabases', 'amphora_logs', 'amphora_logs_13',
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
