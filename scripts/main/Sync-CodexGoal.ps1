[CmdletBinding()]
param(
    [string]$CodexHome,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/CodexGoalProjection.psm1") -Force

$result = Sync-CodexGoalProjection -CodexHome $CodexHome

if ($Json) {
    $result | ConvertTo-Json -Depth 10
}
else {
    Write-Host ""
    Write-Host "Codex Goal Shadow Projection Sync" -ForegroundColor Cyan
    Write-Host ("  Result : {0}" -f $(if ($result.Ok) { "OK" } else { "FAILED" })) -ForegroundColor $(if ($result.Ok) { "Green" } else { "Red" })
    Write-Host ("  Reason : {0}" -f $result.Reason)
    Write-Host ("  Synced : {0} / {1}" -f $result.Synced, $result.Total)
    if ($result.Failed -gt 0) {
        Write-Host ("  Failed : {0}" -f $result.Failed) -ForegroundColor Yellow
    }
    Write-Host ""
}

if (-not $result.Ok) {
    exit 1
}

exit 0
