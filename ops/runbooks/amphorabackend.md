---
audience: internal
---

# `AmphoraBackend` — production DB on SQL-2022's second instance

The "backend / utility" database. Originally framed in team chat as "temporary
data", but in practice it's a long-running operational store: email-event
telemetry from SendGrid + Mailgun, file blobs, a handful of bookkeeping
tables. **Not in the DR pipeline today** — pending retention cleanup before
onboarding (see §"Plan to onboard to DR" below).

## Where it lives

- Instance: **SQL-2022 second instance** (named instance, not the default on
  `10.0.0.35`). Connect using the second-instance port — see your SSMS
  connection profile.
- Recovery model: `SIMPLE` (no log backups, no point-in-time recovery).
- Collation: `SQL_Estonian_CP1257_CI_AS` (matches primaries).
- Settings worth knowing (preserved from a much older schema script —
  inherited any time someone CREATEs DB by scripting from here):
  `ANSI_NULLS OFF`, `QUOTED_IDENTIFIER OFF`, `PARAMETERIZATION SIMPLE`,
  `READ_COMMITTED_SNAPSHOT OFF`. Modern ORMs override these per connection;
  hand-written SPs should be created with `SET QUOTED_IDENTIFIER ON; SET
  ANSI_NULLS ON;` first to avoid quoting weirdness.
- Query Store: **ON** as of 2026-05-11 (1 GB cap, 90-day retention,
  30-min intervals, AUTO capture). Use it instead of plan-cache scraping.

## Inventory snapshot (2026-05-11, post-cleanup of one index)

Total: 10 tables, ~100M rows, ~190 GB data + index (data file is ~313 GB
including free pages; ~120 GB free after today's index drop).

| Table | Rows | Total MB | Notes |
|---|---:|---:|---|
| `dbo.sg_event` | 54 M | ~160,000 | The hot table. One row per email event (delivered / opened / bounced / clicked / etc.) from SendGrid + Mailgun. `created` is the event time. Has triggers (org-id resolution, "is this DB already noted as Opened" check). |
| `dbo.sg_event_old` | 9.1 M | 13,500 | Static archive — last row 2020-08-26. One-time copy of pre-2020 sg_event. Cleanup candidate. |
| `dbo.amphora_file` | 22.5 M | 8,600 | File-related rows, **no datetime column**. Purpose not yet documented. |
| `dbo.amphora_file_aes` | 11.5 M | 7,500 | As above, presumably AES-encrypted variant. Relationship to `amphora_file` not yet documented. |
| `dbo.file_event` | 1.5 M | 616 | **Dead since 2017-12-31.** Abandoned feature. Drop candidate. |
| `dbo.sg_event_log` | 665 K | 222 | Sparse, 9-year span (2017-09 → 2026-01). Likely batch-import audit. |
| `dbo.email_validation` | 81 K | 122 | Active. `validation_time` indexed. |
| `dbo.db_space` | 6 K | 18 | No timestamp. Likely periodic disk-space snapshot. |
| `dbo.amphoradb_event` | 4.5 K | <1 | **Dead since 2017-12-31.** Abandoned feature. Drop candidate. |
| `dbo.sg_event_type` | 11 | <1 | Lookup. Static — Processed / Delivered / Bounce / Open / etc. |

Regenerate via `ops/runbooks/analyze-db.sql` (heuristic-picks the best
datetime column per table for first/last-row dating).

## `sg_event` schema + indexes

29 columns; the load-bearing ones for queries:

- `id bigint` (PK, clustered)
- `email`, `created`, `timestamp` — three datetime-ish columns; `timestamp`
  is what app queries actually filter on (per missing-index telemetry)
- `smtp-id`, `sg_event_id`, `sg_message_id` — identifiers from the email
  provider
- `event` — text event type (Delivered / Bounce / Open / etc.)
- `event_type_id` — int FK to `sg_event_type`
- `org_id` — tenant attribution; resolved by trigger on insert
- `email_provider` — SendGrid / Mailgun discriminator

Six nonclustered indexes (after 2026-05-11 cleanup):

| Index | Size | 93-day seeks | Notes |
|---|---:|---:|---|
| `IX_sgidevent` (event, sg_message_id) | 10 GB | 841 K | Most-read. Likely the "any Open seen for this message?" trigger lookup + reporting. |
| `IX_sg_event_org_id` (org_id) | 1 GB | 583 K | Cheap + heavy. Tenant-scoped queries. |
| `IX_sg_event_smtpid_sgmsgid` (smtp-id, sg_message_id) | 14 GB | 309 K | Outbound-message → events lookups. |
| `IX_sg_event_4col6incB` (sg_message_id, id, smtp-id, timestamp) INCLUDE (email, event, sg_event_id, response, ip, reason) | 60 GB | 3.8 K | Heavy reporting cover index. Earns its keep (~11B logical reads served / 93d) but worth re-evaluating after Query Store gives query-level data. |
| `IX_sg_Event_4col` (sg_message_id, id, smtp-id, org_id) | 14 GB | 5 K | Trigger-supporting. |
| `PK_sg_event` (id) CLUSTERED | 61 GB | — | — |

**Dropped 2026-05-11:** `IX_sg_event_4col6inc` (60 GB) had zero seeks/scans/
lookups in 93 days of production workload — pure write-amplification cost.
Removed for ~60 GB reclaim + lower INSERT cost.

**Notable missing:** no index leads with a datetime column. Date-range queries
(e.g. retention DELETE) will be forced to scan. When we plan the cleanup,
adding `(timestamp)` or `(org_id, timestamp)` will be near-mandatory.

## Workload snapshot (from plan cache, 93-day uptime, 2026-05-11)

- Workhorse: 13,870 executions × 285 ms avg, wide SELECT returning all sg_event
  columns (ORM-generated, `Tbl1004` alias = NHibernate / LinqToSql pattern).
  Total ~66 min CPU + 8.4B logical reads.
- Problem child: same query shape, but 133 executions × **13.7 s each** with
  7.78M logical reads. Total ~30 min CPU. Plausibly parameter-sniffing — a
  bad plan was cached for an outlier parameter and got reused. Query Store
  will show the parameter difference once it has a day of data.
- Triggers: on insert, the trigger reads `inserted`, looks up `[smtp-id]` by
  `sg_message_id`, checks for prior Open events, possibly updates `org_id`.
  Explains the heavy use of `IX_sg_event_smtpid_sgmsgid` and `IX_sgidevent`.

## Why it's not in DR

Two reasons, both fixable:

1. **Lives on a SQL Server instance not yet in the pipeline.** Our Ola jobs
   run on the default instance of SQL-2022 (`10.0.0.35`). The second instance
   would need: its own Ola install (Phase 02), its own `@Directory` pointing
   at RESERV's UNC share, its own `\<INSTANCE>` subfolder on RESERV. Same
   pattern as primary, just scaled out.
2. **It's bloated with multi-year-old data we likely don't need.** Shipping
   ~190 GB of mostly-archive data per FULL is wasteful when half of it is
   provably dead (2017 abandoned tables + 2020 static archive). Cleanup
   before onboarding makes the DR cost proportional to actual operational
   value.

## Plan to onboard to DR

Sketched, not scheduled. Each step is reversible until the last.

1. **Identify `amphora_file` / `amphora_file_aes` purpose** before deciding
   their fate. 16 GB combined, 33 M rows, no timestamp — could be load-bearing
   for app features we don't realise. Ask the team / grep the codebase.
2. **Drop dead 2017 tables**: `file_event`, `amphoradb_event`. Reclaim ~620 MB.
3. **Drop or cold-archive `sg_event_old`** (13 GB, last row 2020-08). If
   anyone reads from it, find them first; otherwise drop.
4. **Define `sg_event` retention** (likely 1-2 years for ops, longer for
   audit/legal — get team input). Add a `(timestamp)` index before any
   deletes, then batched DELETE in 10K-row chunks with a WAITFOR between
   batches so log doesn't balloon (SIMPLE recovery limits log growth but
   doesn't eliminate it; large single DELETE can still bloat tempdb).
5. **Shrink** the data file once free space is large + stable. One-off, not a
   recurring habit.
6. **SIMPLE→FULL** recovery model (`ALTER DATABASE ... SET RECOVERY FULL`).
7. **Install Ola** on SQL-2022's second instance (Phase 02 pattern, separate
   `@Directory` per `<server>$<instance>` Ola token).
8. **Wire jobs** (Phase 04 pattern, ship to `\\10.0.0.47\SqlBackup`).
9. **Initial FULL** + verify on RESERV. Daemon picks it up on next sweep.
10. **Add to the digest** — confirms it shows up in DB inventory and stays
    out of RPO outliers.

## Day-to-day operations

- Query telemetry: SSMS → Object Explorer → AmphoraBackend → Query Store →
  Top Resource Consumers / Tracked Queries / Regressed Queries.
- Per-table sizing / first-last-row sweep: `ops/runbooks/analyze-db.sql`.
- Plan-cache one-off "which queries used index X":
  `sys.dm_exec_query_stats` + `dm_exec_query_plan` + `LIKE '%IX_name%'`
  (pattern from today's session — Query Store does this better once it has data).

## Cross-references

- Local `AmphoraBackend` scratch DB on workstation: see
  `dev-clone-on-workstation.md` §"Scratch write-target DB". Same name,
  completely different role. Always be explicit about server in connection
  strings.
- `AmphoraBackendServer` linked server on SQL-2022 default instance points
  at this DB (`10.0.0.35\SQL22FT,14330`) — useful for ad-hoc queries from
  the default-instance side without re-connecting.
