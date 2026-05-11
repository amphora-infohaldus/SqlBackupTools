# RESERV-2025 (10.0.0.47) -- Warm standby. No backups originate here; this
# server runs SqlBackupTools (continuous-restore daemon) against local
# folders that the primaries write to directly via UNC (\\10.0.0.47\SqlBackup
# = C:\SqlBackup). The planned RichCopy360 RTA hop was skipped -- direct UNC
# is what's deployed.

@{
    ServerShortName          = 'RESERV-2025'
    ServerIP                 = '10.0.0.47'

    # Cert was restored from backup; name matches primaries' intended standard.
    ServerCert               = 'SqlBackupCert'

    # Where primaries write their .bak/.trn via direct UNC
    # (\\10.0.0.47\SqlBackup -> this path on RESERV)
    ReceivedRoot             = 'C:\SqlBackup'

    # Legacy archive (pre-Ola flat-format backups). Leave in place until old
    # pipeline is retired; SqlBackupTools does NOT read from here.
    LegacyArchivePathSQL     = 'C:\SQL-2022'
    LegacyArchivePathPremium = 'C:\PREMIUM-2022'

    # SqlBackupTools invocation -- default instance + future PREMIUM named
    # instance (add when phases/01-reserv-setup/ second-instance install runs).
    MainInstance             = '.'
    PremiumInstance          = '.\PREMIUM'

    # Ola output dir -- only relevant if we ever install Ola on RESERV (not planned).
    OlaOutputFileDirectory   = 'C:\SqlBackup\Logs'
}
