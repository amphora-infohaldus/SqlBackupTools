# RESERV-2025 (10.0.0.47) -- Warm standby. No backups originate here; this
# server runs SqlBackupTools (continuous-restore daemon) against the local
# folders that RichCopy360 RTA populates from the primaries.

@{
    ServerShortName          = 'RESERV-2025'
    ServerIP                 = '10.0.0.47'

    # Cert was restored from backup; name matches primaries' intended standard.
    ServerCert               = 'SqlBackupCert'

    # Where RichCopy360 RTA lands files shipped from primaries
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
