# Values shared across all three servers. Per-server config files
# (SQL-2022.ps1, PREMIUM-2022.ps1, RESERV-2025.ps1) override these.
#
# Keys become sqlcmd -v variables, referenced in SQL files as $(KeyName).

@{
    # ----- Exclusions -----
    # Applied to @Databases for the main FULL/DIFF/LOG jobs that ship to RESERV
    # (amphora_logs is excluded from ship but gets its own local-only jobs).
    # Wildcards: anything matching %restored% or %koolitus% is excluded from
    # ALL backups everywhere (training DBs, ad-hoc restored copies).
    ExcludeListShip  = 'USER_DATABASES, -AmphoraFT, -AmphoraFT_13, -wdimport_cache, -wdimport_ekis, -amphora_logs, -%restored%, -%koolitus%'

    # Applied to the local MONTHLY/YEARLY jobs -- amphora_logs KEPT (local-only
    # long-retention still applies; SOAP messages must be kept 1 year offsite).
    ExcludeListLocal = 'USER_DATABASES, -AmphoraFT, -AmphoraFT_13, -wdimport_cache, -wdimport_ekis, -%restored%, -%koolitus%'

    # ----- LOG cadence -----
    # Starting conservative. Measure after 1 week of running; reduce stepwise:
    # 30 -&gt; 15 -&gt; 5 -&gt; 1. Just edit this value and re-run phases/04-wire-jobs.
    LogIntervalMinutes = 30

    # ----- Schedule times (HHMMSS int, sqlcmd var format) -----
    DailyDiffTime        = 20000      # 02:00  (Mon-Sat)
    MonthlyFullTime      = 33000      # 03:30  (1st of month)
    YearlyFullTime       = 50000      # 05:00  (Jan 1)
    AmphoraLogsFullTime  = 23000      # 02:30  (Sunday)
    AmphoraLogsDiffTime  = 23000      # 02:30  (Mon-Sat, daily)

    # ----- First-fire dates for monthly/yearly -----
    # Update these if scaffolding is done after the "next" target date.
    MonthlyStartDate = 20260501   # next 1st of month
    YearlyStartDate  = 20270101   # next Jan 1

    # ----- Monitoring login -----
    ClaudeLoginName = 'claude'
}
