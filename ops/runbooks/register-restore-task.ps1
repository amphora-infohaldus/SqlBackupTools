# Registers the SqlBackupTools-RestoreCycle Scheduled Task on RESERV.
# Idempotent: unregister first if it already exists.

$taskName = 'SqlBackupTools-RestoreCycle'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\SqlBackupTools\reserv-restore-cycle.ps1'

# Windows Task Scheduler rejects [TimeSpan]::MaxValue in RepetitionDuration XML.
# 10 years is "forever" for our purposes.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskName $taskName `
    -Description 'Continuous restore: sweep shipped .trn files and apply via SqlBackupTools.exe' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings | Out-Null

Get-ScheduledTask -TaskName $taskName |
    Get-ScheduledTaskInfo |
    Format-List TaskName, LastRunTime, NextRunTime, LastTaskResult, NumberOfMissedRuns
