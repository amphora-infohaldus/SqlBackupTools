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

    # FULL/DIFF/LOG @Directory for Ola jobs. NOTE: the deployed value here has
    # NOT been verified against the live job step. PREMIUM-2022 was confirmed
    # to write direct-UNC (\\10.0.0.47\SqlBackup) -- SQL-2022 likely the same,
    # but check the live `DatabaseBackup - USER_DATABASES - FULL` job step
    # before re-running phases/04-wire-jobs/main-jobs.sql here.
    ShipLocalPath         = 'W:\SqlBackup\ship'
    MonthlyLocalPath      = 'W:\SqlBackup\MONTHLY'
    YearlyLocalPath       = 'W:\SqlBackup\YEARLY'
    AmphoraLogsLocalPath  = 'W:\SqlBackup\amphora_logs_local'

    # Output-file directory for Ola's per-DB stdout logs
    OlaOutputFileDirectory = 'C:\SqlBackup\Logs'
}
