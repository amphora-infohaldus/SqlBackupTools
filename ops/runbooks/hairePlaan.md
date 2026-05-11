---
audience: internal
---

# SQL DR häireplaan — mis teha, kui asi läheb metsa

**Kellele.** Kõigile, kes saavad igahommikust `DR digest`-meili või kes peavad
valves olema, kui Ingmar pole kättesaadav. Ei eelda sügavat SQL Serveri
tundmist — eeldab oskust avada SSMS, käivitada PowerShelli ja SSH-d.

**Millal seda kasutada.** Kui hommikune digest näitab KOLLAST või PUNAST
staatust, või kui keegi kaebab, et mingi raport / bot ei tööta ja kahtlustad,
et taga on andmebaasi-probleem.

**Mis see EI ole.** Automaatse ümberlülitumise juhend. Meie skeem on
**ühesuunaline DR** (käsitsi käivitatav), mitte HA (kõrgkäideldavus). Ükski
süsteem ei lülita ennast iseseisvalt ümber.

---

## 1. Iga päev — digest-meil

Iga päev **08:00** paiku saabub aadressile `ingmar@interinx.com` meil
teemaga `DR digest [STAATUS] - RESERV-2025 - <kuupäev>`. Saatja:
`sqlbackup-dr@amphora.ee`.

| Staatus | Tähendus | Reageering |
|---|---|---|
| **ROHELINE** | Kõik korras. RESERV saab primaaridelt LOG-koopiad õigeaegselt, restore-tsükkel jookseb tõrgeteta, kettal piisavalt ruumi. | Ei tee midagi. |
| **KOLLANE** | 1–5 andmebaasi viimasest restore-st on möödunud >60 min, või muu väiksem probleem. | Mine **2. sammu** ja vaata, mis täpselt maha jäänud on. |
| **PUNANE** | Restore-tsükli SQL Agent ülesanne lõppes veaga, või rohkem kui 5 andmebaasi maha jäänud. | **2. samm** ja seejärel **3. samm** — alusta diagnoosimist. |

Kui digest **ei saabu üldse** (vaata ka rämpsposti) — see on omaette
probleem, vt **6. samm**.

---

## 2. Esimene reageering — vaata, mis on lahti

Mis enne kõike vaadata, kui digest näitab kollast/punast:

### 2.1 Loe digest-meili ennast lõpuni

Digest-meili sees on neli osa:
- **Restore-cycle task** — kas Windows Task Scheduler ülesanne jookseb edukalt
  (Last result peab olema `0`). Kui pole, mine punkti **3.1**.
- **Database inventory** — peaks olema umbes **152 andmebaasi**, kõik
  `RESTORING` staatuses. Kui mõni on `ONLINE` (välja arvatud `master`,
  `model`, `msdb`, `tempdb`), siis keegi on midagi käsitsi taastanud.
- **RPO outliers** — andmebaasid, kus viimane LOG-i rakendamine oli üle
  60 minuti tagasi. Vaata, **millised** ja **kui kaua** maha jäänud.
- **Disk** — RESERV-i kettaruum. `C:` peab olema vähemalt **15% vaba**
  (~2.5 TB), `H:` (HyperV ketas) eraldi mure ei tee.

### 2.2 Ühenda RESERV-iga

```powershell
ssh -i $env:USERPROFILE\.ssh\claude_ai_ed25519 svc_claude_ssh@10.0.0.47
```

(Kasutaja `svc_claude_ssh` on automaatkontosse, võti on Ingmari profiilis.
Kui võti puudub või kasutajaks pole keegi peale Ingmari, vaata
`memory/project_amphora_ssh_sops_access.md` või küsi Ingmarilt.)

Edukal ühendamisel peaks olema `cmd.exe` prompt RESERV-2025 peal.

### 2.3 Vaata kiiret seisu

RESERV-il SSH-i kaudu:

```cmd
sqlcmd -S . -E -W -Q "SET NOCOUNT ON; SELECT COUNT(*) AS total, SUM(CASE WHEN state_desc='RESTORING' THEN 1 ELSE 0 END) AS restoring FROM sys.databases WHERE database_id > 4;"
```

Peaks andma midagi nagu `total=152, restoring=152`. Kui `restoring < total`,
siis mõni andmebaas on ootamatus seisus.

Ja:

```cmd
schtasks /Query /TN SqlBackupTools-RestoreCycle /V /FO LIST | findstr /R "Last.Run Last.Result Next.Run Status"
```

`Last Result: 0` = edukas, kõik muu = tõrge.

---

## 3. Levinumad probleemid ja lahendused

### 3.1 Restore-tsükli ülesanne kukkus (Last Result ≠ 0)

**Sümptom.** Digest PUNANE, "Last result" mitte-null. Restore-tsükkel ei käi.

**Esimese rea diagnostika.** Vaata kõige uuemat logifaili:

```cmd
dir /B /O:-D C:\SqlBackupTools\logs\restore-*.log
```

Esimene rida on uusim. Ava see (näiteks `notepad C:\SqlBackupTools\logs\restore-<kuupäev>.log`)
ja vaata, kus täpselt midagi katki läks. Tüüpilised vead:

| Mida näed | Mis viga | Mida teha |
|---|---|---|
| `Login failed` | SQL Serveri õigused katki | Vt punkt 3.6 |
| `Cannot open device` | Mõni `.trn` või `.bak` fail ei ole loetav | Vt punkt 3.2 |
| `LSN ... too recent` | Logi-keti katkemine | Vt punkt 3.4 |
| `Disk full` / `not enough space` | Ketas täis | Vt punkt 3.5 |
| `Timeout expired` | SQL Server koormatud | Oota 5 min, vaata uuesti |

**Käivita käsitsi.** Kui logi ei aita selgust saada, käivita tsükkel käsitsi
ja vaata reaalajas:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File C:\SqlBackupTools\reserv-restore-cycle.ps1
```

Lase joosta lõpuni, vaata ekraanil olevaid hoiatusi.

---

### 3.2 LOG-failid ei jõua RESERV-isse

**Sümptom.** Üks või mitu andmebaasi RPO outliers nimekirjas, kõikidel
maha jäänud kestus enam-vähem ühepalju (näiteks 90 min). Tähendab, et failid
ei ole jõudnud kohale.

**Diagnoos.** Vaata jagusid `\\10.0.0.47\SqlBackup\<primaar>\<db>\LOG\`:

```cmd
dir C:\SqlBackup\PREMIUM-2022\<db>\LOG\ | findstr ".trn"
```

Vaata viimast kuupäeva. Kui see on rohkem kui 30 minutit tagasi (meil on
seadistatud 15-min LOG-tsükkel), siis primaaridel midagi ei õhtuks ühe.

**Mida teha.** Primaarsel serveril (PREMIUM-2022 või SQL-2022) tuleb kontrollida
Ola Hallengreni LOG-ülesannet:

1. Logi SSMS-ga primaarsele serverisse (sysadmin õigustega).
2. Object Explorer → SQL Server Agent → Jobs → `DatabaseBackup - USER_DATABASES - LOG`.
3. Paremklõps → "View History" — kas viimane käivitus oli edukas?
4. Kui mitte, vaata stepi väljundit ja `master.dbo.CommandLog` tabelist.

Kui ka primaaril LOG-ülesanne ei käivitu, on tegemist suurema probleemiga —
helista Ingmarile või lülita SQL Server Agent uuesti sisse:

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'DatabaseBackup - USER_DATABASES - LOG';
```

### 3.3 Üks konkreetne andmebaas jääb maha (teised on OK)

**Sümptom.** Digestis on RPO outliers nimekirjas üks-kaks andmebaasi, ülejäänud
~150 on OK. LOG-failid jõuavad RESERV-isse, aga ei rakendu.

**Diagnoos.** Vaata, kas LOG-failid on tegelikult kohal:

```cmd
dir C:\SqlBackup\PREMIUM-2022\<probleemi-db>\LOG\
```

Kui on (uus `.trn` viimase 15 min jooksul), aga rakendamine ei toimu — tõenäoliselt
on tegemist **LSN-keti katkemisega**. Vt järgmine punkt.

### 3.4 LSN-keti katkemine

**Sümptom.** Konkreetne andmebaas jääb järjest enam maha. Logifailis on midagi
sellist nagu *"This backup set cannot be applied because the database has not
been rolled forward far enough"* või *"LSN too recent"*.

**Mida teha.** Vajalik on andmebaasi taasalgseta — võtta primaarsel uus FULL
backup ja taastada see RESERV-il `WITH NORECOVERY`. See on käsitööd. Etapid:

1. **Primaaril** (oletame PREMIUM-2022):
   ```sql
   EXEC master.dbo.DatabaseBackup
       @Databases = '<db_name>',
       @Directory = '\\10.0.0.47\SqlBackup',
       @BackupType = 'FULL',
       @Verify = 'Y', @Compress = 'Y', @CheckSum = 'Y',
       @Encrypt = 'Y', @EncryptionAlgorithm = 'AES_256',
       @ServerCertificate = 'SqlBackupCert',
       @CleanupTime = 720, @LogToTable = 'Y';
   ```

2. **RESERV-il** vana koopia kustuta ja uus FULL taasta:
   ```sql
   USE master;
   ALTER DATABASE [<db_name>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
   DROP DATABASE [<db_name>];
   RESTORE DATABASE [<db_name>]
   FROM DISK = N'C:\SqlBackup\PREMIUM-2022\<db>\FULL\<uusFULL-fail>.bak'
   WITH NORECOVERY, REPLACE, CHECKSUM,
        MOVE N'<data-loogiline-nimi>' TO N'C:\Data\<db_name>.mdf',
        MOVE N'<log-loogiline-nimi>'  TO N'C:\Data\<db_name>_log.ldf';
   ```

   Loogilised failinimed: `RESTORE FILELISTONLY FROM DISK = N'<failitee>';`.

3. Järgmine restore-tsükkel (5 min jooksul) hakkab LOG-koopiaid rakendama.

**Konkreetne näide** sellest, kuidas seda 11.05.2026 `amphorafw_infohaldus`
puhul tehti: vt `ops/runbooks/dev-clone-on-workstation.md` lõppu või git-logi
commit `63479d1`.

### 3.5 Ketas täis (RESERV-il)

**Sümptom.** Logis `Disk full`, või digestis "Free %" on alla 10%.

**Mida teha kiiresti:**

1. Vaata, kus ruum kulub:
   ```powershell
   Get-ChildItem C:\SqlBackup -Directory | ForEach-Object {
       $size = (Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum
       [pscustomobject]@{Path=$_.Name; GB=[math]::Round($size/1GB,1)}
   } | Sort-Object GB -Descending | Format-Table
   ```

2. **Ära kustuta käsitsi `.trn` faile** — Ola hoolitseb selle eest, et
   vanad failid kuluvad ära `@CleanupTime = 720` (30 päeva) tunni järel,
   aga ainult need failid, mis tema enda registris on.

3. Kui peate ruumi vabastama kiiresti:
   - Kustuta vana **MONTHLY** ja **YEARLY** backupid kataloogist
     `C:\SqlBackup\<primaar>\<db>\FULL\` (vana kuupäevaga `.bak` failid) —
     **ainult need, millest on RESERV-il koopia juba edukalt rakendatud**.
   - Andmebaasifaile (`C:\Data\*.mdf`, `*.ldf`) **ära kunagi puutu**.

4. Pikem lahendus: lisa ketas. RESERV-il on hetkel ainult `C:` (16.5 TB)
   ja `H:` (HyperV, 4.9 TB). Saaks lisada veel SSD partitsiooni
   `D:` jaoks ja kolida `C:\SqlBackup\` sinna.

### 3.6 SQL Server õigused katkesid (3110 viga)

**Sümptom.** Logis viga *"User does not have permission to RESTORE database"*,
SQL viga 3110.

**Mida teha.**

```sql
USE master;
ALTER SERVER ROLE [sysadmin] ADD MEMBER [NT AUTHORITY\SYSTEM];
GO
SELECT IS_SRVROLEMEMBER('sysadmin', 'NT AUTHORITY\SYSTEM');  -- peab tagastama 1
```

Põhjus: turvalisuse karmistamine eemaldab `BUILTIN\Administrators → sysadmin`
loginist, ja SYSTEM ei pärinda enam sysadmin-õigusi. Restore-tsükli ülesanne
jookseb SYSTEM-ina. Detailid: `ops/runbooks/observability-handoff.md` "Gotcha #7".

---

## 4. Suur õnnetus — üks primaaridest on kadunud

**Sümptom.** PREMIUM-2022 või SQL-2022 ei vasta üldse — riistvaratõrge,
serveriruumis põleng, krüptolukkijate rünnak, mis iganes.

**Mida _kohe_ teha:**

1. **Ära paanitse.** RESERV-2025 sisaldab kõikide andmebaaside värsket
   koopiat (kuni 20 min vanune sõltuvalt LOG-tsüklist). Andmed pole kadunud.
2. **Ära käivita RESERV-2025 peal `RESTORE WITH RECOVERY`-d ilma plaanita.**
   Niipea kui RESERV andmebaasid on `ONLINE` (mitte `RESTORING`), enam
   primaarilt järgneva taastamine ei tööta — keti viimane samm on tehtud.
3. **Hinda olukord.** Kas primaar tuleb varsti tagasi (tunni sees)? Kui jah:
   parem oota, ära aja paanikas. Kui mitte / kahtled / on kindel kadu — vt
   järgmine punkt.

**Failover RESERV-isse** (kogu protseduur):

Hoia `ops/runbooks/failover.md` käeulatuses. Lühidalt:

1. Veendu, et viimased LOG-id on primaarilt RESERV-isse jõudnud
   (käivita restore-tsükkel käsitsi).
2. Tee `RESTORE DATABASE <db> WITH RECOVERY` iga andmebaasi kohta.
   SqlBackupTools'il on selleks `--runRecovery` lipp, mis teeb selle massiliselt.
3. Parandage `@@SERVERNAME` kui nimi peaks vahetuma.
4. Suunake rakenduste DNS / connection-string'id RESERV-2025-le.
5. Testige proovipäringuga, kas iga peamine rakendus saab andmebaasi kätte.

**Hoiatus.** Kui pole täiesti kindel, mida teed, **helista Ingmarile esimese
asjana**. DR failover on suure mõjuga ja pole automaatselt tagasipööratav.

---

## 5. Mida _ei_ tee, isegi kui paistab, et oleks vaja

- **Ära kustuta** ühtegi andmebaasi RESERV-ilt, ilma et oled kontrollinud,
  kas see on tahtlikult sealt välja jäetud (`amphora_logs_13` näiteks on
  meeleldi välja lülitatud — vt `reserv-restore-cycle.ps1` kommentaare).
- **Ära käivita** `RESTORE WITH RECOVERY`-d RESERV-il, kui pole *kindel*,
  et failover on praegu õige tegevus. Kord taastatud `ONLINE`-i ei saa enam
  uusi LOG-e rakendada — keti viimane samm.
- **Ära shrinki** `C:\SqlBackup` peal olevaid andmebaaside `.mdf` faile.
  Vaata `ops/runbooks/amphorabackend.md` selgituse jaoks, miks see üldiselt
  halb mõte on.
- **Ära peata** SqlBackupTools-RestoreCycle ülesannet "ajutiselt", kui sa
  ei pane kuhugi meeldetuletust seda uuesti käivitada. Iga peatatud tund
  tähendab vähem värsked andmed RESERV-il.
- **Ära muuda** primaaridel Ola Hallengreni töid (`DatabaseBackup - USER_DATABASES - LOG/FULL/DIFF`)
  ilma `ops/phases/04-wire-jobs/main-jobs.sql`-i läbi vaatamata. Muutused
  rakenduvad järgmisel `ops/run.ps1` käivitusel ja kirjutavad sinu käsitsi
  muutused üle.

---

## 6. Digest ei jõua kohale

**Sümptom.** Üks või rohkem hommikut ei tule meili aadressile
`ingmar@interinx.com`.

**Diagnostika:**

1. Kas Task Scheduler ülesanne RESERV-il käivitub?
   ```cmd
   schtasks /Query /TN SqlBackupTools-DRDigest /V /FO LIST | findstr /R "Last.Run Last.Result Next.Run Status"
   ```
   `Last Result: 0` = edukas käivitus, `Next Run Time` peab näitama
   järgmist hommikut 08:00.

2. Kas SMTP-relay töötab?
   ```powershell
   Test-NetConnection mail.datanet.ee -Port 25
   ```
   Peab tagastama `TcpTestSucceeded: True`.

3. Vaata, kas meil jõudis rämpsposti.

4. Kui kõik OK aga meili ikka pole — käivita digest käsitsi:
   ```cmd
   powershell -NoProfile -ExecutionPolicy Bypass -File C:\SqlBackupTools\dr-digest.ps1
   ```
   Vaata, kas tuleb veateade.

---

## 7. Pikemad detailid — kust leida

| Mida tahad teada | Kus on |
|---|---|
| Süsteemi arhitektuur ja "mida on tehtud" | `ops/runbooks/observability-handoff.md` |
| Kõikide etappide nimekiri ja millises järjekorras | `ops/GETTING-STARTED.md` |
| Konfiguratsioon serverite kaupa | `ops/config/<serveri-nimi>.ps1` |
| Failover-protseduur (täielik) | `ops/runbooks/failover.md` |
| RESERV-i restore-tsükli skript | `ops/runbooks/reserv-restore-cycle.ps1` |
| Digest skript | `ops/runbooks/dr-digest.ps1` |
| AmphoraBackend (eraldi andmebaas SQL-2022 teisel instantsil, **ei ole DR-is**) | `ops/runbooks/amphorabackend.md` |
| Töö arendusarvutil — kloonide loomine | `ops/runbooks/dev-clone-on-workstation.md` |

---

## 8. Kontaktid

- **Ingmar (peamine vastutav)** — Slack / telefoni teel
- **Repo** — `https://github.com/amphora-infohaldus/SqlBackupTools`
- **RESERV-2025 SSH** — `ssh -i %USERPROFILE%\.ssh\claude_ai_ed25519 svc_claude_ssh@10.0.0.47`
- **Primaaride IP-d** — PREMIUM-2022 = `10.0.0.45`, SQL-2022 = `10.0.0.35`,
  RESERV-2025 = `10.0.0.47`

---

## Lõpetuseks

Süsteem on mõeldud nii, et **roheline päev on igapäev**. Kui näed kollast
või punast ja sa pole kindel, mis teha — Ingmari häirimine on alati parem
valik kui valedele klahvidele vajutamine. Andmebaaside taastamise
operatsioonid on sageli pöördumatud.

Viimati uuendatud: 2026-05-11.
