Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "AuditRepository.psm1")

function Sync-GoalRouterOrchestrationEvent {
    <#
        既存のGoalRouter.psm1（Resolve-GoalRouter / Invoke-GoalRouterRoute）の
        判定結果を、変更せずそのままOrchestration Audit Eventとして記録する
        疎結合な統合レイヤー。GoalRouter.psm1自体は変更しない。

        呼び出し元パターン:
          $route = Resolve-GoalRouter -ProjectDir $dir -Trigger "cron"
          Sync-GoalRouterOrchestrationEvent -Route $route | Out-Null
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [object]$Route,

        [string]$TaskId = "",
        [string]$RunId = "",
        [string]$ProjectRoot = ""
    )

    $detail = @{
        mode             = $Route.Mode
        primary          = $Route.Primary
        specialized      = $Route.Specialized
        effective        = $Route.Effective
        confidence       = $Route.Confidence
        reason           = $Route.Reason
        evidence_used    = @($Route.EvidenceUsed)
        locked_by_user   = [bool]$Route.LockedByUser
        session_locked   = [bool]$Route.SessionLocked
        plane            = $Route.Plane
    }

    return (Add-OrchestrationAuditEvent -TaskId $TaskId -RunId $RunId -EventType "goal_router.routed" -Detail $detail -ProjectRoot $ProjectRoot)
}

Export-ModuleMember -Function @(
    "Sync-GoalRouterOrchestrationEvent"
)
