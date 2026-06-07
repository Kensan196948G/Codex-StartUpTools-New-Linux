[CmdletBinding()]
param(
    [string]$Project = "Codex-StartUpTools-New-Linux",
    [switch]$SkipPester,
    [switch]$SkipDryRun,
    [switch]$AllowDirty,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/Config.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/ArchitectureCheck.psm1") -Force
Import-Module (Join-Path $script:StartupRoot "scripts/lib/ReleaseCheck.psm1") -Force

$report = Invoke-ReleaseCheck `
    -ProjectRoot $script:StartupRoot `
    -Project $Project `
    -SkipPester:$SkipPester `
    -SkipDryRun:$SkipDryRun `
    -AllowDirty:$AllowDirty

if ($Json) {
    $report | ConvertTo-Json -Depth 20
}
else {
    Write-ReleaseCheckReport -Report $report
}

if (-not $report.passed) {
    exit 1
}

exit 0
