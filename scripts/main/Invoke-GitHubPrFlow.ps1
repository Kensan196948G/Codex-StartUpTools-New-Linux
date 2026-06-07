[CmdletBinding()]
param(
    [string]$Base = "main",
    [string]$Title = "Prepare v0.2.0",
    [switch]$CreateDraft,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/GitHubPrFlow.psm1") -Force

$report = Invoke-GitHubPrFlow `
    -ProjectRoot $script:StartupRoot `
    -Base $Base `
    -Title $Title `
    -CreateDraft:$CreateDraft

if ($Json) {
    $report | ConvertTo-Json -Depth 20
}
else {
    Write-GitHubPrFlowReport -Report $report
}

if (-not $report.passed) {
    exit 1
}

exit 0
