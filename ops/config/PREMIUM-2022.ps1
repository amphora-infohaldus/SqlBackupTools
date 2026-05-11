# PREMIUM-2022 (10.0.0.45) -- Premium tier, 30 day retention.

@{
    ServerShortName       = 'PREMIUM-2022'
    ServerIP              = '10.0.0.45'
    ServerTier            = 'Premium'

    ServerCert            = 'SqlBackupCert'

    # Short-term retention for FULL/DIFF/LOG (30 days per Premium tier)
    RetentionHours        = 720

    # Weekly FULL starts at 04:00 Sunday (2h offset from SQL-2022)
    WeeklyFullTime        = 40000

    # FULL/DIFF/LOG @Directory for Ola jobs. On this server the deployed jobs
    # write straight to RESERV-2025 via UNC (no local ship-then-mirror hop --
    # simpler than the planned RichCopy chain, and the path that was easier to
    # bring up). Re-running phases/04-wire-jobs/main-jobs.sql will re-wire
    # the job steps to this path.
    ShipLocalPath         = '\\10.0.0.47\SqlBackup'
    MonthlyLocalPath      = 'D:\SqlBackup\MONTHLY'
    YearlyLocalPath       = 'D:\SqlBackup\YEARLY'
    AmphoraLogsLocalPath  = 'D:\SqlBackup\amphora_logs_local'

    OlaOutputFileDirectory = 'C:\SqlBackup\Logs'
}
