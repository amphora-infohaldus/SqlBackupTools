# Bootstrap script executed on RESERV-2025 to install Alloy.
# Assumes the installer + config + nssm + Alloy binary are already staged.

$ErrorActionPreference = 'Stop'

# Pre-place binary so installer's download path is skipped.
New-Item -ItemType Directory -Force -Path 'C:\Tools\alloy' | Out-Null
if (-not (Test-Path 'C:\Tools\alloy\alloy-windows-amd64.exe')) {
    Copy-Item -Force 'C:\staging\alloy\alloy-windows-amd64.exe' 'C:\Tools\alloy\alloy-windows-amd64.exe'
}

& 'C:\staging\alloy\install-alloy-service.ps1' `
    -Environment  production `
    -OtlpEndpoint 'https://otel.svc.amphora.ee' `
    -BearerToken  '9180ffd37bb20f2687d845bc33b75b3e18b44b3d169e8d8b017a2b559d087569'
