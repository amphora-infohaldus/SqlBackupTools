<#
Install Ola Hallengren's MaintenanceSolution.sql on this box.

Reads ShipLocalPath + OlaOutputFileDirectory from ops/config/$hostname.ps1
and patches the three DECLARE lines at the top of Ola's script before running.
#>
[CmdletBinding()]
param(
    [string] $Server    = $env:COMPUTERNAME,
    [string] $SqlServer = '.'
)

$ErrorActionPreference = 'Stop'
$opsRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')

# ---- Load config
$shared   = & (Join-Path $opsRoot 'config\shared.ps1')
$perServer = & (Join-Path $opsRoot "config\$Server.ps1")
$cfg = $shared
foreach ($k in $perServer.Keys) { $cfg[$k] = $perServer[$k] }

$backupRoot  = $cfg.ShipLocalPath
$outputLog   = $cfg.OlaOutputFileDirectory

if (-not $backupRoot)  { throw "Missing ShipLocalPath in config for $Server" }
if (-not $outputLog)   { throw "Missing OlaOutputFileDirectory in config for $Server" }

# ---- Ensure output dir + ship root exist
New-Item -Path $outputLog   -ItemType Directory -Force | Out-Null
New-Item -Path $backupRoot  -ItemType Directory -Force | Out-Null

# ---- Download Ola's latest
$stagePath = Join-Path $env:TEMP 'MaintenanceSolution.sql'
Write-Host "Downloading Ola Hallengren's MaintenanceSolution.sql..."
Invoke-WebRequest -Uri 'https://ola.hallengren.com/scripts/MaintenanceSolution.sql' -OutFile $stagePath -UseBasicParsing

# ---- Customize header DECLAREs
$sql = Get-Content -LiteralPath $stagePath -Raw -Encoding UTF8
$sql = $sql -replace 'DECLARE @BackupDirectory nvarchar\(max\)\s+= NULL',
                     ("DECLARE @BackupDirectory nvarchar(max)     = N'{0}'" -f $backupRoot)
$sql = $sql -replace 'DECLARE @CleanupTime int\s+= NULL',
                     'DECLARE @CleanupTime int                   = 168'
$sql = $sql -replace 'DECLARE @OutputFileDirectory nvarchar\(max\)\s+= NULL',
                     ("DECLARE @OutputFileDirectory nvarchar(max) = N'{0}'" -f $outputLog)
Set-Content -LiteralPath $stagePath -Value $sql -Encoding UTF8

Write-Host ""
Write-Host "Customized DECLAREs in $stagePath :"
Select-String -Path $stagePath -Pattern 'DECLARE @BackupDirectory|DECLARE @CleanupTime|DECLARE @OutputFileDirectory' |
    Select-Object -First 3 | ForEach-Object { "  " + $_.Line.TrimEnd() } | Out-Host

# ---- Run
Write-Host ""
Write-Host "Installing to $SqlServer..." -ForegroundColor Cyan
& sqlcmd -S $SqlServer -E -b -i $stagePath
if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited $LASTEXITCODE" }
Write-Host "OK" -ForegroundColor Green

Remove-Item -LiteralPath $stagePath -Force
