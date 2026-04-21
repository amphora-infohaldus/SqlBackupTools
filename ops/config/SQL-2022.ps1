# SQL-2022 (10.0.0.35) -- Standard tier, 14 day retention.
# Cert was installed under the name 'MyCertificate' (historic; same key
# material as PREMIUM's 'SqlBackupCert'). Rename is a future cleanup.

@{
    ServerShortName       = 'SQL-2022'
    ServerIP              = '10.0.0.35'
    ServerTier            = 'Standard'

    # Encryption cert name (for @ServerCertificate in Ola)
    ServerCert            = 'MyCertificate'

    # Short-term retention for FULL/DIFF/LOG (14 days per Standard tier)
    RetentionHours        = 336

    # Weekly FULL starts at 02:00 Sunday
    WeeklyFullTime        = 20000

    # Local backup paths (Ola writes here; RichCopy360 RTA ships to RESERV)
    ShipLocalPath         = 'W:\SqlBackup\ship'
    MonthlyLocalPath      = 'W:\SqlBackup\MONTHLY'
    YearlyLocalPath       = 'W:\SqlBackup\YEARLY'
    AmphoraLogsLocalPath  = 'W:\SqlBackup\amphora_logs_local'

    # Output-file directory for Ola's per-DB stdout logs
    OlaOutputFileDirectory = 'C:\SqlBackup\Logs'
}
