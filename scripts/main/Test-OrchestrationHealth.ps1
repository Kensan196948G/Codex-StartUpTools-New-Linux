[CmdletBinding()]
param(
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/PostgreSqlStore.psm1") -Force

$connectionInfo = Get-PostgreSqlConnectionInfo
$health = Test-PostgreSqlHealth

$report = [pscustomobject]@{
    ConnectionEnvVar      = $connectionInfo.EnvVar
    ConnectionConfigured  = $connectionInfo.Available
    ClientToolAvailable   = (Test-PostgreSqlClientTool)
    Healthy               = $health.Healthy
    Reason                = $health.Reason
}

if ($Json) {
    $report | ConvertTo-Json -Depth 10
}
else {
    Write-Host ""
    Write-Host "Orchestration PostgreSQL Health Check" -ForegroundColor Cyan
    Write-Host ("  Connection env var   : {0}" -f $report.ConnectionEnvVar)
    Write-Host ("  Connection configured: {0}" -f $report.ConnectionConfigured)
    Write-Host ("  psql client available: {0}" -f $report.ClientToolAvailable)
    Write-Host ("  Healthy              : {0}" -f $report.Healthy) -ForegroundColor $(if ($report.Healthy) { "Green" } else { "Yellow" })
    Write-Host ("  Reason               : {0}" -f $report.Reason)
    Write-Host ""
    if (-not $report.ConnectionConfigured) {
        Write-Host "  接続未設定の場合、Repositoryモジュールは自動的にFile Fallback（logs/orchestration/*.jsonl）へ切り替わります。" -ForegroundColor DarkGray
    }
    Write-Host ""
}

exit 0
