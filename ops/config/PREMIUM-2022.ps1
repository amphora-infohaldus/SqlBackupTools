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

    # Local backup paths
    ShipLocalPath         = 'D:\SqlBackup\ship'
    MonthlyLocalPath      = 'D:\SqlBackup\MONTHLY'
    YearlyLocalPath       = 'D:\SqlBackup\YEARLY'
    AmphoraLogsLocalPath  = 'D:\SqlBackup\amphora_logs_local'

    OlaOutputFileDirectory = 'C:\SqlBackup\Logs'
}
