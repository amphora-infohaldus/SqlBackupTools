---
audience: internal
---

# Amphora SQL DR Automation

> **New here?** Start with [`GETTING-STARTED.md`](GETTING-STARTED.md) — step-by-step task list, top to bottom.

This folder holds all operational scripts for the continuous log-shipping / DR pipeline from **SQL-2022** and **PREMIUM-2022** to **RESERV-2025**. It lives inside the `amphora-infohaldus/SqlBackupTools` repo (a fork of Lucca's tool, which we use for the continuous-restore daemon on RESERV).

> **The `.NET` source tree in `src/` is upstream Lucca's tool — do not touch it here.** Everything Amphora-specific lives under `ops/`.

## Layout

```
ops/
├── config/              Per-server + shared + SOPS-encrypted secrets
├── phases/              Execution order: 01 → 06
├── discovery/           Read-only inventory queries (safe to run anytime)
├── admin/               Idempotent admin setup (logins, grants)
├── monitoring/          Day-2 queries (backup lag, chain health)
├── runbooks/            Failover, rotation, troubleshooting
├── .sops.yaml           SOPS recipient config (age public keys)
├── run.ps1              Wrapper: resolves hostname → config → sqlcmd
└── README.md
```

## Bootstrap (once per server)

1. Clone the repo and keep it up to date:
   ```powershell
   cd C:\Sources
   git clone https://github.com/amphora-infohaldus/SqlBackupTools.git
   # or on an existing clone:
   git pull
   ```

2. Install `sops.exe` and `age.exe` on the box. Standalone binaries, drop into `C:\tools\` (or add to PATH).

3. Generate an age keypair:
   ```powershell
   mkdir "$env:USERPROFILE\.config\sops\age" -Force
   age-keygen -o "$env:USERPROFILE\.config\sops\age\keys.txt"
   # Print the public key:
   (Get-Content "$env:USERPROFILE\.config\sops\age\keys.txt" | Where-Object { $_ -match 'public key' }) -replace '# public key: ', ''
   ```

4. Send the public key to whoever maintains `ops/.sops.yaml`. After the file is updated and `sops updatekeys ops/config/secrets.enc.yaml` runs, `git pull` on this server. The local age key now decrypts.

5. Set env var so SOPS finds the key:
   ```powershell
   [System.Environment]::SetEnvironmentVariable('SOPS_AGE_KEY_FILE', "$env:USERPROFILE\.config\sops\age\keys.txt", 'User')
   ```

## Operational workflow

From an elevated PowerShell on any of the three servers:

```powershell
cd C:\Sources\SqlBackupTools
git pull
.\ops\run.ps1 phases\04-wire-jobs\main-jobs.sql
```

`run.ps1` auto-detects the hostname, loads `ops/config/shared.ps1` + `ops/config/<hostname>.ps1` + decrypted `ops/config/secrets.enc.yaml`, and runs the chosen script via `sqlcmd` with all values injected as variables.

## Execution order

| Phase | Folder | When to run | Where |
|---|---|---|---|
| 01 | `phases/01-reserv-setup/` | Once when building RESERV-2025 | RESERV only |
| 02 | `phases/02-ola-install/` | Once per primary | SQL-2022, PREMIUM-2022 |
| 03 | `phases/03-preflight/` | Once per primary before Phase 4 | SQL-2022, PREMIUM-2022 |
| 04 | `phases/04-wire-jobs/` | Once per primary (re-run OK, idempotent) | SQL-2022, PREMIUM-2022 |
| 05 | `phases/05-richcopy/` | Once — configure RichCopy360 RTA jobs | SQL-2022, PREMIUM-2022 |
| 06 | `phases/06-cutover/` | Kick off initial FULL, then enable LOG job | SQL-2022, PREMIUM-2022 |

## Credential handling

All secrets are in `ops/config/secrets.enc.yaml`, encrypted with SOPS using age. Plain-text secrets never touch disk. Rotation: `sops ops/config/secrets.enc.yaml` (opens editor, re-encrypts on save), commit, pull on each server.

See `ops/runbooks/credential-rotation.md` (future) for the full rotation flow.
