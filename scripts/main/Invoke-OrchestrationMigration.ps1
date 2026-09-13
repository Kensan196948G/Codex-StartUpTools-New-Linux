[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/OrchestrationMigration.psm1") -Force

$result = Invoke-OrchestrationMigration -DryRun:$DryRun

if ($Json) {
    $result | ConvertTo-Json -Depth 20
}
else {
    Write-Host ""
    Write-Host "Orchestration Migration" -ForegroundColor Cyan
    Write-Host ("  Mode    : {0}" -f $(if ($DryRun) { "dry-run" } else { "apply" }))
    Write-Host ("  Result  : {0}" -f $(if ($result.Ok) { "OK" } else { "FAILED" })) -ForegroundColor $(if ($result.Ok) { "Green" } else { "Red" })
    Write-Host ("  Reason  : {0}" -f $result.Reason)
    Write-Host ("  Applied : {0}" -f (($result.Applied) -join ", "))
    Write-Host ("  Pending : {0}" -f (($result.Pending) -join ", "))
    Write-Host ""
}

if (-not $result.Ok) {
    exit 1
}

exit 0
