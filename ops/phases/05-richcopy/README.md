---
audience: internal
---

# Phase 05 — RichCopy360 RTA configuration

Configure RichCopy360 on each primary so that the Ola ship folders are
mirrored to RESERV-2025 in real time. No SQL to run in this phase — it's
all configured in the RichCopy UI on each primary (or via its config files,
if you prefer).

## Existing setup today

RichCopy360 is already running on **SQL-2022** and **PREMIUM-2022** doing
two things:

1. Upload local backups to Hetzner offsite
2. Copy local backups to RESERV at `C:\SQL-2022\` and `C:\PREMIUM-2022\`

RTA (Real-Time Agent) runs on **RESERV-2025** as the receiving end.

This existing configuration can stay as-is during transition (it's watching
the OLD flat-format backup folders). We just add a new source path for the
Ola-output folders.

## Jobs to add (one per primary)

### On SQL-2022

| Setting | Value |
|---|---|
| Source | `W:\SqlBackup\ship\` (everything underneath) |
| Destination | `C:\SqlBackup\` on RESERV-2025 |
| Recurse | yes |
| Preserve directory structure | yes (Ola's `<server>\<db>\<type>\` layout is mirrored verbatim) |
| Mode | RTA |
| Delete destination files when source deleted | **NO** (RESERV holds longer retention than primary) |
| Overwrite | newer (file-date based) |
| Encryption on the wire | RichCopy's default (backups themselves are AES-256 encrypted too) |

Net result: `W:\SqlBackup\ship\SQL-2022\amphorafw_tartu\FULL\SQL-2022_amphorafw_tartu_FULL_20260421_020000.bak` on the source becomes `C:\SqlBackup\SQL-2022\amphorafw_tartu\FULL\SQL-2022_amphorafw_tartu_FULL_20260421_020000.bak` on RESERV.

### On PREMIUM-2022

| Setting | Value |
|---|---|
| Source | `D:\SqlBackup\ship\` |
| Destination | `C:\SqlBackup\` on RESERV-2025 |
| Rest — same as SQL-2022 |

Note: both primaries share the same **destination root** (`C:\SqlBackup\`) on RESERV. The server-name subfolder in Ola's layout prevents collisions: `C:\SqlBackup\SQL-2022\*` and `C:\SqlBackup\PREMIUM-2022\*` stay separate.

## Leave existing jobs alone

The existing RichCopy jobs that mirror OLD flat-format backups (`W:\DAILY\` → `C:\SQL-2022\`, etc.) keep running until the old MaintenancePlan / external orchestrator is retired in Phase 06. They don't interfere with the new Ola path because the source/destination paths differ.

After Phase 06 cutover is stable for ≥1 week and the old backup pipeline is disabled, the legacy RichCopy jobs can be retired too.

## Firewall

RichCopy's agent-to-agent protocol (not raw SMB) handles its own auth and transport. The TCP port 445 firewall rule on RESERV (set up in earlier phase planning) is no longer needed for the backup path. You can keep it open for other admin uses or close it — doesn't affect the pipeline.

## Verify it's working

After configuring + enabling the new RichCopy jobs, then running a manual backup via the Phase 06 kickoff script, check RESERV within a minute or so:

```powershell
# On RESERV, from elevated PowerShell:
Get-ChildItem C:\SqlBackup -Recurse -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 10 FullName, Length, LastWriteTime
```

You should see new `.bak` files appearing, matching the Ola filename pattern (`<server>_<db>_<type>_<date>_<time>.bak`).

## When LOG cadence gets tightened

When we eventually reduce the LOG backup interval (30 min → 15 → 5 → 1), the RTA job config doesn't change. RichCopy just picks up more files per unit time. If transit becomes a bottleneck, check the RichCopy dashboard for queue depth.
