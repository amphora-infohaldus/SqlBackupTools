<#
.SYNOPSIS
    Run an ops SQL script with variables substituted from per-server config + SOPS-decrypted secrets.

.DESCRIPTION
    Auto-detects hostname, loads:
      1. ops/config/shared.ps1
      2. ops/config/<hostname>.ps1
      3. decrypted ops/config/secrets.enc.yaml (via `sops -d`)
    Merges into one hashtable (later wins), then does direct `$(VarName)`
    substitution in the target SQL file, writes the result to a temp file,
    and invokes sqlcmd against it.

    We avoid sqlcmd's `-v` / `:setvar` mechanism because:
      - `:setvar` has higher precedence than `-v`, so defaults in the script
        silently override wrapper-injected values
      - sqlcmd's `-v` parsing rejects values containing commas (common in our
        Ola exclusion lists) on PS 5.1
      Direct substitution sidesteps both traps.

.PARAMETER ScriptPath
    Relative path (from ops/ root) to the .sql file to run.

.PARAMETER Server
    Override auto-detected hostname. Default: $env:COMPUTERNAME.
    Tip: NetBIOS truncates to 15 chars. Use this param for hostnames > 15 chars.

.PARAMETER SqlServer
    sqlcmd -S value. Default '.' (local default instance).

.PARAMETER NoSecrets
    Skip SOPS decryption (for dry-runs).

.PARAMETER KeepTempFile
    Keep the resolved .sql file on disk instead of deleting -- useful for
    debugging what got substituted.

.EXAMPLE
    .\run.ps1 phases\04-wire-jobs\main-jobs.sql

.EXAMPLE
    .\run.ps1 phases\03-preflight\simple-to-full.sql -SqlServer '.\PREMIUM'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ScriptPath,

    [string] $Server    = $env:COMPUTERNAME,
    [string] $SqlServer = '.',
    [switch] $NoSecrets,
    [switch] $KeepTempFile
)

$ErrorActionPreference = 'Stop'
$opsRoot = $PSScriptRoot

# ---- Resolve target script
$fullScriptPath = Join-Path $opsRoot $ScriptPath
if (-not (Test-Path -LiteralPath $fullScriptPath)) {
    throw "Script not found: $fullScriptPath"
}

# ---- Load shared + per-server config
function Import-Config([string] $path) {
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    $result = & $path
    if (-not ($result -is [hashtable])) {
        throw "$path must return a hashtable as its last expression."
    }
    return $result
}

$sharedPath = Join-Path $opsRoot 'config\shared.ps1'
$serverPath = Join-Path $opsRoot "config\$Server.ps1"

$config = Import-Config $sharedPath
$serverCfg = Import-Config $serverPath
foreach ($k in $serverCfg.Keys) { $config[$k] = $serverCfg[$k] }

if ($config.Count -eq 0) {
    Write-Warning "No config found for server '$Server'. Expected $serverPath"
}

# ---- Load SOPS-decrypted secrets (optional)
if (-not $NoSecrets) {
    $secretsEnc = Join-Path $opsRoot 'config\secrets.enc.yaml'
    if (Test-Path -LiteralPath $secretsEnc) {
        if (-not (Get-Command sops.exe -ErrorAction SilentlyContinue)) {
            Write-Warning "sops.exe not in PATH; skipping secret decryption. Pass -NoSecrets to silence."
        } else {
            $decrypted = & sops -d $secretsEnc
            if ($LASTEXITCODE -ne 0) {
                throw "sops -d failed for $secretsEnc (exit $LASTEXITCODE)"
            }
            # Naive one-level YAML parse (no need for a real parser for key: value files)
            foreach ($line in $decrypted) {
                if ($line -match '^\s*([A-Za-z0-9_]+)\s*:\s*"?(.*?)"?\s*$') {
                    $config[$Matches[1]] = $Matches[2]
                }
            }
        }
    }
}

# ---- Do direct $(Var) substitution in the script
# Single-quote escaping: values going into N'...' literals need '' for apostrophes.
$scriptText = Get-Content -LiteralPath $fullScriptPath -Raw -Encoding UTF8
$resolvedText = $scriptText
foreach ($k in $config.Keys) {
    $v = [string]$config[$k]
    $vEscaped = $v -replace "'", "''"
    $pattern = '\$\(' + [regex]::Escape($k) + '\)'
    $resolvedText = $resolvedText -replace $pattern, $vEscaped
}

# Detect any leftover $(Foo) -- that's a var the script expected but config didn't provide
$leftover = [regex]::Matches($resolvedText, '\$\(([A-Za-z0-9_]+)\)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
if ($leftover) {
    Write-Error ("Unresolved variable(s) -- missing from config: " + ($leftover -join ', '))
    Write-Error "Add them to config\shared.ps1, config\$Server.ps1, or secrets.enc.yaml and re-run."
    exit 2
}

# ---- Write resolved SQL to temp file and invoke sqlcmd
$tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("ops-" + [System.IO.Path]::GetRandomFileName() + ".sql"))
Set-Content -LiteralPath $tempFile -Value $resolvedText -Encoding UTF8

Write-Host "===== ops/run.ps1 =====" -ForegroundColor Cyan
Write-Host "Server:    $Server"
Write-Host "SqlServer: $SqlServer"
Write-Host "Script:    $ScriptPath"
Write-Host "Resolved:  $tempFile"
Write-Host "Variables: $($config.Count) substituted"
Write-Host ""

try {
    # -b: terminate on error
    # -E: trusted connection (Windows auth). Override SqlServer + use -U/-P if mixed auth needed.
    & sqlcmd -S $SqlServer -E -b -i $tempFile
    $exit = $LASTEXITCODE
}
finally {
    if (-not $KeepTempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Kept temp file: $tempFile" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($exit -eq 0) { Write-Host "OK ($exit)" -ForegroundColor Green }
else              { Write-Host "FAILED ($exit)" -ForegroundColor Red }
exit $exit
