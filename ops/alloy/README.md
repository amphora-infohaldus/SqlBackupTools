---
audience: internal
---

# Alloy on RESERV-2025

Grafana Alloy runs as a Windows service on RESERV, tailing the
SqlBackupTools Serilog output and forwarding to the prod Amphora OTel
endpoint. Logs land in Loki at `grafana.svc.amphora.ee`.

## Files

- `config.alloy` — RESERV-specific: `loki.source.file` → OTel processor chain → `otelcol.exporter.otlphttp` cloud.
- `bootstrap-reserv.ps1` — thin wrapper around the org installer. Drop onto RESERV alongside the Alloy binary, `nssm.exe`, and `install-alloy-service.ps1` (copied from `AmphoraServerConfig/alloy/`) and run as admin.

## Deploy / redeploy

The installer is idempotent, so the deploy flow is:

```powershell
# From this workstation (one-time — Alloy binary is 280 MB):
scp alloy-windows-amd64.exe svc_claude_ssh@10.0.0.47:C:/staging/alloy/

# Every time config.alloy changes:
scp ops/alloy/config.alloy svc_claude_ssh@10.0.0.47:C:/staging/alloy/
scp C:/sources/AmphoraServerConfig/alloy/install-alloy-service.ps1 svc_claude_ssh@10.0.0.47:C:/staging/alloy/
scp C:/sources/AmphoraServerConfig/alloy/nssm.exe svc_claude_ssh@10.0.0.47:C:/staging/alloy/
scp ops/alloy/bootstrap-reserv.ps1 svc_claude_ssh@10.0.0.47:C:/staging/alloy/

# Over SSH, as admin:
ssh svc_claude_ssh@10.0.0.47 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\staging\alloy\bootstrap-reserv.ps1'
```

## Verify

```powershell
# Service state
Get-Service GrafanaAlloy

# Exporter counters — sent vs failed
(Invoke-WebRequest 'http://127.0.0.1:12345/metrics' -UseBasicParsing).Content `
    -split "`n" | Select-String 'otelcol_exporter_sent_log|otelcol_exporter_send_failed|loki_source_file_files_active'
```

Expected shape after a few minutes:

```
otelcol_exporter_sent_log_records_total{...} 18327
otelcol_exporter_send_failed_log_records_total{...} 0
loki_source_file_files_active_total{...} 1
```

In Grafana, query `{service_name="sqlbackuptools"}` under Loki.

## What's routed

| Source | Destination | Label for querying |
|---|---|---|
| `C:\SqlBackupTools\logs\*.log` (Serilog daily) | Loki via prod OTLP | `{service_name="sqlbackuptools", deployment_environment="production", host_name="RESERV-2025"}` |

## Not yet routed (planned)

- Windows perf counters → Prometheus/Mimir (add `prometheus.exporter.windows`)
- SQL Server metrics → Prometheus/Mimir (add `prometheus.exporter.mssql`)
- Per-cycle custom metrics via Prom textfile (via a side PS script that runs after each scheduled-task cycle)
- In-exe OTLP push if/when `Amphora.Telemetry` is wired into the .NET code

## Secrets

Bearer token for `https://otel.svc.amphora.ee` is the same one committed in `AmphoraKubernetes/infrastructure/proxy/nginx-prod.conf`. Stored in NSSM's `AppEnvironmentExtra` (authoritative) and the on-disk `alloy-secrets.env` (admins+SYSTEM only, for foreground debugging). Not encrypted — same posture as AmphoraPro hosts running the same collector pattern.

## Upgrading Alloy

```powershell
# On workstation with internet:
curl -LO https://github.com/grafana/alloy/releases/download/<version>/alloy-windows-amd64.exe.zip
# Extract, scp to RESERV, re-run bootstrap-reserv.ps1 (it stops + reinstalls the service).
```
