# Registers the SqlBackupTools-MetricsCollector Scheduled Task on RESERV.
# Runs every minute, emits Prom textfile that Alloy picks up for the cloud.

$taskName = 'SqlBackupTools-MetricsCollector'

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\SqlBackupTools\metrics-collector.ps1'

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskName $taskName `
    -Description 'Emits Prometheus textfile metrics (DB state, RPO, ship freshness, disk) for Alloy' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings | Out-Null

Get-ScheduledTask -TaskName $taskName |
    Get-ScheduledTaskInfo |
    Format-List TaskName, LastRunTime, NextRunTime, LastTaskResult
