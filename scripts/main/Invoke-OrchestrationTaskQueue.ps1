[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Lease", "Heartbeat", "Complete", "Fail", "RecoverStale", "ListStale")]
    [string]$Action,

    [string]$Id = "",
    [string]$Worker = "",
    [int]$LeaseSeconds = 300,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartupRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $script:StartupRoot "scripts/lib/TaskQueue.psm1") -Force

$result = switch ($Action) {
    "Lease" {
        Get-NextOrchestrationTask -Worker $Worker -LeaseSeconds $LeaseSeconds
    }
    "Heartbeat" {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Worker)) {
            throw "-Id と -Worker を指定してください"
        }
        Send-OrchestrationTaskHeartbeat -Id $Id -Worker $Worker -LeaseSeconds $LeaseSeconds
    }
    "Complete" {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Worker)) {
            throw "-Id と -Worker を指定してください"
        }
        Complete-OrchestrationTask -Id $Id -Worker $Worker -Status "completed"
    }
    "Fail" {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Worker)) {
            throw "-Id と -Worker を指定してください"
        }
        Complete-OrchestrationTask -Id $Id -Worker $Worker -Status "failed"
    }
    "RecoverStale" {
        Reset-StaleOrchestrationTask
    }
    "ListStale" {
        @{ Ok = $true; Reason = "ok"; Tasks = @(Get-StaleOrchestrationTask) }
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
}
else {
    Write-Host ""
    Write-Host "Orchestration Task Queue: $Action" -ForegroundColor Cyan
    $result | Format-List | Out-String | Write-Host
}

if ($result.PSObject.Properties["Ok"] -and -not $result.Ok) {
    exit 1
}

exit 0
