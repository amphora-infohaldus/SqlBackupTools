# Monitoring (day-2 ops)

**TODO** — populate after Phase 6 cutover is stable.

Queries planned:
- **Backup chain health** per DB: LastFull, LastDiff, LastLog timestamps + gap vs expected cadence
- **RichCopy lag** — newest file on primary vs newest file on RESERV (same DB/type)
- **Restore lag** on RESERV — newest file on disk vs last `RESTORE LOG` applied by SqlBackupTools
- **SqlBackupTools daemon state** — is the restore loop running, any errors
- **CommandLog error tail** on each primary

Alerting: pushed to Slack via `Amphora.Telemetry` or OTel equivalent — wiring TBD.
