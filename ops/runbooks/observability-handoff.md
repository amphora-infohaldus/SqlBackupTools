# Observability stack — state + handoff

Snapshot of what's live for the RESERV continuous-restore pipeline as of
2026-04-23, plus the gotchas hit getting there so the next operator doesn't
re-discover them.

## What's live

**On RESERV-2025 (10.0.0.47):**

| Component | Path | Purpose |
|---|---|---|
| `SqlBackupTools.exe` (today's main) | `C:\SqlBackupTools\SqlBackupTools.exe` | Continuous restore daemon |
| Wrapper | `C:\SqlBackupTools\reserv-restore-cycle.ps1` | Sweeps both primary folders sequentially |
| Metrics collector | `C:\SqlBackupTools\metrics-collector.ps1` | Emits Prom textfile every 1 min |
| Logs | `C:\SqlBackupTools\logs\restore*.log` | Serilog, daily-rotated |
| Prom textfile | `C:\SqlBackupTools\metrics\sqlbackup.prom` | Atomic writes from collector |
| Alloy service | `GrafanaAlloy` via NSSM | Tails logs + scrapes Windows + textfile → prod OTel |
| Alloy install | `C:\Tools\alloy\` | Binary, config, secrets |

**Two Scheduled Tasks, both SYSTEM principal:**

| Task | Cadence | Script |
|---|---|---|
| `SqlBackupTools-RestoreCycle` | every 5 min | `reserv-restore-cycle.ps1` |
| `SqlBackupTools-MetricsCollector` | every 1 min | `metrics-collector.ps1` |

**In the cluster (prod):**

| Thing | Location | Status |
|---|---|---|
| Prometheus rule group `sqlbackuptools` | `AmphoraKubernetes/workloads/telemetry-prod/configmaps/alert-rules.yaml` | ConfigMap applied; **pending pod restart to take effect** (see gotcha #1) |
| Alertmanager routing | `workloads/telemetry-prod/configmaps/alertmanager.yaml` | Still stub (localhost/-/healthy) — no Slack/email wired yet |
| Grafana dashboard JSON | `SqlBackupTools/ops/dashboards/sqlbackuptools.json` | Not imported — manual import via Grafana UI |

## Verified data flow

On RESERV:
```
# Service up
Get-Service GrafanaAlloy   # Running

# Sent records + failure counters
(Invoke-WebRequest 'http://127.0.0.1:12345/metrics' -UseBasicParsing).Content `
  -split "`n" | Select-String 'otelcol_exporter_sent|send_failed|loki_source_file_files_active'
```

Last observed: `otelcol_exporter_sent_log_records_total=3030+`,
`otelcol_exporter_sent_metric_points_total=1709+`,
`otelcol_exporter_send_failed_log_records_total=0`,
`loki_source_file_files_active_total=1`.

In Grafana (once datasource UIDs match the import):
- Loki: `{service_name="sqlbackuptools"}`
- Prom/Mimir: `sqlbackup_rpo_seconds`, `sqlbackup_ship_newest_trn_age_seconds`, etc.

## Still to do (easy wins, not urgent)

1. **Restart Prometheus pod** to pick up the new rules (see gotcha #1 for the exact how). Until done, alerts don't fire.
2. **Wire real Alertmanager receivers** (Slack webhook, optionally email via Mailgun). Current config routes everything to `localhost:9093/-/healthy` — a no-op.
3. **Import the dashboard JSON** manually in Grafana UI. Datasource UIDs in the JSON assume `"loki"` + default Mimir/Prometheus — adjust at import time.
4. **Windows Defender exclusion** for `C:\SqlBackup\*` on RESERV (AV lock on mid-ship `.trn` files is a failure mode in the catalogue, not yet fixed).
5. **.trn retention task** on RESERV. At ~125 GB/day ingest and 6.3 TB free, runway is ~50 days — so not urgent, but worth a scheduled `Remove-Item` task at a 7-day retention window.
6. **Auto-recovery tier 1** (detect chain break → apply next DIFF). Designed in `observability-handoff.md` section below, not built.
7. **`.NET Amphora.Telemetry` wiring in the exe** for direct OTLP push of in-process custom metrics (cycle duration, per-DB error reasons). Currently all metrics come from the side PowerShell.
8. **Mailgun API key** — secrets-file wiring exists in the exe but the key hasn't been pulled from AmphoraPro's `Web.config` and added to `ops/config/secrets.enc.yaml`.
9. **Set up SOPS on RESERV** (generate its age key, add to `.sops.yaml`, run `sops updatekeys`) so the daemon can use `--secrets-file` — today it runs without secrets entirely (integrated auth to local SQL, no Slack, no email).

## Gotchas hit today — read before making changes

### 1. Prometheus ConfigMap update requires pod restart, not rollout

`rules.yml` in the Prometheus deployment is mounted via `subPath: rules.yml`.
Kubernetes does **not** propagate ConfigMap updates to `subPath` mounts — it's
a hard limitation, not a bug. So `/-/reload` has no effect until the pod is
restarted.

`kubectl rollout restart deployment prometheus` **won't work** either: the
PVC backing `/prometheus` is `ReadWriteOnce`, and the Deployment's default
`RollingUpdate` strategy tries to spin up a new pod before terminating the
old one → `Multi-Attach error` stuck in `ContainerCreating`.

**Correct recipe:**
```bash
kubectl --kubeconfig .../clusters/prod/kubeconfig.yaml -n telemetry \
    delete pod -l app=prometheus
```
The Deployment controller recreates the pod. Brief (~30-60s) gap in scraping,
data on PVC is preserved. Verify rules loaded after:
```bash
kubectl exec <new-pod> -- wget -q -O- http://localhost:9090/api/v1/rules
# Expect a group "sqlbackuptools"
```

Same pattern applies to any `subPath`-mounted ConfigMap in the cluster.

### 2. Alloy 1.6.1 textfile-collector syntax is `text_file`, not `textfile`

Latest Alloy docs show `textfile { directories = [...] }`. That's post-1.7.
In 1.6.1 (what's installed per `AmphoraServerConfig`), it's:

```alloy
prometheus.exporter.windows "host" {
  enabled_collectors = [..., "textfile"]
  text_file {
    text_file_directory = "C:\\path"
  }
}
```

Comment in `ops/alloy/config.alloy` notes this. On Alloy upgrade, swap the
block name + use a list for the directory arg.

### 3. Alloy installer ACL-locks `alloy-secrets.env` on first install

`AmphoraServerConfig/alloy/install-alloy-service.ps1` runs `icacls
alloy-secrets.env /inheritance:r /grant:r "Administrators:(R)" "SYSTEM:(R)"`
right after writing the file. Re-running the installer then fails with
`Access to the path is denied` because the current user (who is in
Administrators but only got `R`) can't rewrite the file.

Workaround baked into `ops/alloy/bootstrap-reserv.ps1`: grant `F` and remove
the file before re-invoking the installer. Don't remove it — this is the
primary way to redeploy Alloy config, and the installer doesn't self-heal.

### 4. PowerShell 5.1 reads UTF-8 `.ps1` without BOM as CP1252

Em-dashes, en-dashes, fancy quotes, arrows in comments become `�?�` and break
parsing. If you write a `.ps1` and paste includes any of those (common
copy-from-chat or copy-from-docs), either:
- Stick to ASCII (preferred): `-- ` instead of `—`, `'` instead of `'`, etc.
- Save as UTF-8 **with BOM** if you must use Unicode

I ran into this with `metrics-collector.ps1` today; fixed by byte-level
replacement. The pattern also applies to any `.ps1` under `ops/runbooks/`.

### 5. RESERV has no outbound internet

Installer's "download Alloy from GitHub release" path doesn't work — the
host can't reach github.com. Pattern for deploys that need binaries:
pre-download on workstation, scp to `C:\staging\`, installer picks up the
cached binary (the `if -not Test-Path { download }` guard in the installer
handles this).

Same for SqlBackupTools exe — `dotnet publish` locally, scp the output.

### 6. The exe's Serilog falls back to CWD if `--logs` dir doesn't exist

`DirectoryInfo.Exists` returns false for missing paths. If `--logs
C:\SqlBackupTools\logs` is passed but the directory doesn't exist, Serilog
silently falls back to `logs/` relative to the working directory. Under
SYSTEM principal that's `C:\Windows\System32\logs\`. Alloy tailing only
`C:\SqlBackupTools\logs\` never sees those lines.

Fix baked into `reserv-restore-cycle.ps1` line 8:
`New-Item -ItemType Directory -Force -Path $logDir`. Don't remove.

## Who runs what, end to end

```
  ┌──────────────────────────┐       ┌──────────────────────────┐
  │ SQL-2022 primary         │       │ PREMIUM-2022 primary     │
  │ Ola LOG job @ 30m        │       │ Ola LOG job @ 30m        │
  └──────────┬───────────────┘       └──────────┬───────────────┘
             │ ship folder                      │ ship folder
             ▼                                  ▼
             └──────────── RichCopy RTA ────────┘
                             │
                             ▼
  ┌────────────────────────────────────────────────────────────┐
  │ RESERV-2025                                                │
  │                                                            │
  │  C:\SqlBackup\{SQL-2022,PREMIUM-2022}\<db>\{FULL,LOG}\     │
  │                     │                                      │
  │                     ▼                                      │
  │  SqlBackupTools-RestoreCycle (every 5 min)                 │
  │    → reserv-restore-cycle.ps1                              │
  │    → SqlBackupTools.exe restore --folder ... twice         │
  │    → logs to C:\SqlBackupTools\logs\restore<date>.log      │
  │                                                            │
  │  SqlBackupTools-MetricsCollector (every 1 min)             │
  │    → metrics-collector.ps1                                 │
  │    → writes C:\SqlBackupTools\metrics\sqlbackup.prom       │
  │                                                            │
  │  GrafanaAlloy (continuous)                                 │
  │    ├── loki.source.file tails logs                         │
  │    ├── prometheus.exporter.windows (+ textfile)            │
  │    └── forwards OTLP/HTTP with Bearer to                   │
  │        https://otel.svc.amphora.ee                         │
  └─────────────────────────────────┬──────────────────────────┘
                                    │
                                    ▼
                ┌─────────────────────────────┐
                │ Prod cluster (K8s)          │
                │ nginx @ 10.0.5.1 → Alloy →  │
                │ Loki, Mimir, Tempo          │
                │ Prometheus rules → Alertmgr │
                │ Grafana (grafana.svc.amphora.ee)  │
                └─────────────────────────────┘
```

## Reference files

- `ops/alloy/config.alloy` — Alloy config (River syntax)
- `ops/alloy/bootstrap-reserv.ps1` — RESERV installer wrapper
- `ops/alloy/README.md` — per-file notes
- `ops/runbooks/reserv-restore-cycle.ps1` — restore sweep wrapper
- `ops/runbooks/register-restore-task.ps1` — registers the 5-min task
- `ops/runbooks/metrics-collector.ps1` — textfile emitter
- `ops/runbooks/register-metrics-task.ps1` — registers the 1-min task
- `ops/runbooks/reserv-continuous-restore.md` — the original deploy plan (pre-execution)
- `ops/dashboards/sqlbackuptools.json` — Grafana dashboard (importable)
- In AmphoraKubernetes: `workloads/telemetry-prod/configmaps/alert-rules.yaml` — rule group `sqlbackuptools`
