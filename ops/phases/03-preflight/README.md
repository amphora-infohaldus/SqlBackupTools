# Phase 03 — Preflight: SIMPLE → FULL

Flips all user DBs to FULL recovery, except those matching the exclusion
rules (explicit names + `%restored%` + `%koolitus%` patterns).

## Run on each primary

```powershell
cd C:\Sources\SqlBackupTools
.\ops\run.ps1 phases\03-preflight\simple-to-full.sql
```

Idempotent — DBs already in FULL are skipped; excluded DBs are skipped.

## Important caveat

The moment a DB flips to FULL, its transaction log stops being truncated
until a new FULL backup is taken. Between this phase and Phase 04 + 06
(which together produce the initial FULL), logs will grow. Don't leave DBs
sitting in FULL for days without a FULL backup.

Recommended sequencing: run Phase 03, then Phase 04 (wiring) immediately,
then Phase 06 (initial FULL kickoff) within the same day.

## What the script skips

- Explicit: `AmphoraFT`, `AmphoraFT_13`, `wdimport_cache`, `wdimport_ekis`, `amphora_logs`
- Pattern: anything matching `%restored%` (ad-hoc restored DBs) or `%koolitus%` (training DBs)

Add more to the explicit list by editing the script's `@excluded` table.
Add new patterns by adding more `AND name NOT LIKE N'%pattern%'` clauses.
