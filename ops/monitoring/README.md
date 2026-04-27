---
audience: internal
---

# Monitoring

Day-2 observability for the RESERV continuous-restore pipeline is live.
For the current state — what's deployed, what's pending, the data-flow
diagram, and the gotchas hit getting there — see
[`../runbooks/observability-handoff.md`](../runbooks/observability-handoff.md).

Highlights:

- Metrics: `metrics-collector.ps1` writes a Prometheus textfile every
  1 min; Alloy on RESERV scrapes + ships to prod OTel.
- Logs: Serilog on RESERV → Alloy → Loki at `grafana.svc.amphora.ee`.
- Dashboard JSON committed at [`../dashboards/sqlbackuptools.json`](../dashboards/sqlbackuptools.json) —
  importable in Grafana UI.
- Alert rules in `AmphoraKubernetes/workloads/telemetry-prod/configmaps/alert-rules.yaml`
  (rule group `sqlbackuptools`).

Open items (Alertmanager receivers, dashboard auto-import, Defender exclusion,
.trn retention) are tracked in the handoff doc's §"Still to do".
