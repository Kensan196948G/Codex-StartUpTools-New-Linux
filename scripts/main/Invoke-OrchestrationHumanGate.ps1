[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Request", "ListPending", "Approve", "Deny")]
    [string]$Action,

    [string]$Gate = "",
    [string]$RunId = "",
    [string]$Reason = "",
    [string]$Id = "",
    [string]$DecidedBy = "",
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/ApprovalRepository.psm1") -Force

$result = switch ($Action) {
    "Request" {
        if ([string]::IsNullOrWhiteSpace($Gate)) {
            throw "-Gate を指定してください"
        }
        Request-OrchestrationHumanApproval -Gate $Gate -RunId $RunId -Reason $Reason
    }
    "ListPending" {
        @{ Ok = $true; Reason = "ok"; Pending = @(Get-PendingOrchestrationHumanApproval) }
    }
    "Approve" {
        if ([string]::IsNullOrWhiteSpace($Id)) {
            throw "-Id を指定してください"
        }
        Approve-OrchestrationHumanGate -Id $Id -DecidedBy $DecidedBy -Reason $Reason
    }
    "Deny" {
        if ([string]::IsNullOrWhiteSpace($Id)) {
            throw "-Id を指定してください"
        }
        Deny-OrchestrationHumanGate -Id $Id -DecidedBy $DecidedBy -Reason $Reason
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
}
else {
    Write-Host ""
    Write-Host "Orchestration Human Gate: $Action" -ForegroundColor Cyan
    $result | Format-List | Out-String | Write-Host
}

if ($result.PSObject.Properties["Ok"] -and -not $result.Ok) {
    exit 1
}

exit 0
