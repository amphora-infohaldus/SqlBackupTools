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
    #
    # KNOWN DRIFT: PREMIUM-2022's deployed job step has a shorter exclusion
    # list (no -amphora_logs / -%restored% / -%koolitus%). Re-running
    # phases/04-wire-jobs/main-jobs.sql will overwrite the deployed list with
    # this one -- adds amphora_logs exclusion + the two patterns. Verify that's
    # what you want before re-running. (SQL-2022's deployed list is not yet
    # verified; assume similar drift until confirmed.)
    ExcludeListShip  = 'USER_DATABASES, -AmphoraFT, -AmphoraFT_13, -wdimport_cache, -wdimport_ekis, -amphora_logs, -%restored%, -%koolitus%'

    # Applied to the local MONTHLY/YEARLY jobs -- amphora_logs KEPT (local-only
    # long-retention still applies; SOAP messages must be kept 1 year offsite).
    ExcludeListLocal = 'USER_DATABASES, -AmphoraFT, -AmphoraFT_13, -wdimport_cache, -wdimport_ekis, -%restored%, -%koolitus%'

    # ----- LOG cadence -----
    # Measured run-time of the LOG sweep on each primary is well under a minute
    # (PREMIUM-2022 ~5-12s for 26 DBs; SQL-2022 ~40-55s for 130 DBs), so 15min
    # gives ample headroom. Tighten further (5, then 1) only after re-measuring.
    LogIntervalMinutes = 15

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
