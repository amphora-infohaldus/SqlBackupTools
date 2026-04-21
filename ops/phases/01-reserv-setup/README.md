# Phase 01 — RESERV-2025 setup

Already done for the default instance during our initial build (collation
rebuild, cert restore, claude login, firewall). This folder holds scripts
for the **second SQL instance (`\PREMIUM`)** installation, which is still
pending.

## Still to do

1. Install SQL Server 2022 named instance `PREMIUM` on RESERV-2025:
   ```cmd
   setup.exe /QS /ACTION=Install /FEATURES=SQLENGINE ^
     /INSTANCENAME=PREMIUM ^
     /SQLCOLLATION=SQL_Estonian_CP1257_CI_AS ^
     /SQLSYSADMINACCOUNTS="RESERV-2025\Ülemus" ^
     /SECURITYMODE=SQL /SAPWD="<from SOPS secrets: sa_password>" ^
     /SQLSVCACCOUNT="RESERV-2025\Ülemus" /SQLSVCPASSWORD="<from SOPS: ulemus_password>" ^
     /AGTSVCACCOUNT="RESERV-2025\Ülemus" /AGTSVCPASSWORD="<from SOPS: ulemus_password>" ^
     /IACCEPTSQLSERVERLICENSETERMS
   ```
2. Enable TCP/IP for the named instance, bind port 1434.
3. Firewall rule for 1434 inbound from 10/8.
4. Install `SqlBackupCert` (restore from the .cer/.pvk pair).
5. Run `ops/admin/create-claude-readonly.sql` against the new instance.

Full runbook: **TODO** — build this into a single PowerShell script once
we know the install media path.

## Current status

- Default instance: ready (collation matches, cert installed, claude present, TCP open)
- `\PREMIUM` instance: not yet installed. Blocks restoration of PREMIUM-2022's `amphora_logs_13`, `AmphoraFT_*`, etc. to their own namespace.

Decision deferred per user conversation — since we're using RichCopy (not SMB
push) and amphora_logs is excluded from ship, the only name collision between
primaries is resolved by excluding it. Other DBs don't collide. Whether the
second instance is still needed depends on whether any *other* name collision
appears in the future.

**Recommendation:** defer the second-instance install until:
- Phase 06 cutover is proven and stable
- A user DB name collision OTHER than `amphora_logs` appears

If no collision appears, single-instance on RESERV is sufficient and simpler.
