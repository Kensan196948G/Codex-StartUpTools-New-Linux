Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "PostgreSqlStore.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "CodexGoalClient.psm1")

function Set-CodexGoalProjectionRecord {
    <#
        単一Goalをcodex_goal_projectionsへUPSERTする。
        Codex内部SQLite（~/.codex/goals_*.sqlite）へは一切書き込まない
        （読み取りはGet-CodexGoalList経由のみ、こちらは投影先PostgreSQLへの書き込み専用）。
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Writes to the orchestration control-plane projection store, not a local host system change requiring ShouldProcess.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [object]$Goal
    )

    $tokenBudgetSql = if ($null -eq $Goal.TokenBudget -or $Goal.TokenBudget -eq "") { "NULL" } else { [string][int64]$Goal.TokenBudget }
    $tokensUsedSql = if ($null -eq $Goal.TokensUsed -or $Goal.TokensUsed -eq "") { "0" } else { [string][int64]$Goal.TokensUsed }
    $timeUsedSql = if ($null -eq $Goal.TimeUsedSeconds -or $Goal.TimeUsedSeconds -eq "") { "0" } else { [string][int64]$Goal.TimeUsedSeconds }
    $updatedAtMsSql = if ($null -eq $Goal.UpdatedAtMs -or $Goal.UpdatedAtMs -eq "") { "0" } else { [string][int64]$Goal.UpdatedAtMs }

    $sql = @"
INSERT INTO codex_goal_projections (thread_id, goal_id, objective, status, token_budget, tokens_used, time_used_seconds, codex_updated_at_ms, synced_at)
VALUES ({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7}, now())
ON CONFLICT (thread_id) DO UPDATE SET
    goal_id = EXCLUDED.goal_id,
    objective = EXCLUDED.objective,
    status = EXCLUDED.status,
    token_budget = EXCLUDED.token_budget,
    tokens_used = EXCLUDED.tokens_used,
    time_used_seconds = EXCLUDED.time_used_seconds,
    codex_updated_at_ms = EXCLUDED.codex_updated_at_ms,
    synced_at = now();
"@ -f `
        (ConvertTo-PostgreSqlLiteral -Value $Goal.ThreadId), `
        (ConvertTo-PostgreSqlLiteral -Value $Goal.GoalId), `
        (ConvertTo-PostgreSqlLiteral -Value $Goal.Objective), `
        (ConvertTo-PostgreSqlLiteral -Value $Goal.Status), `
        $tokenBudgetSql, $tokensUsedSql, $timeUsedSql, $updatedAtMsSql

    return (Invoke-PostgreSqlCommand -Sql $sql)
}

function Sync-CodexGoalProjection {
    <#
        Get-CodexGoalList（読み取り専用）の結果をcodex_goal_projectionsへ同期する。
        Codex内部DBが無い/読めない場合はAvailable=$falseを縮退動作として返す
        （例外にしない。PostgreSQL未接続時も同様にOk=$falseで縮退する）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$CodexHome
    )

    $goalList = Get-CodexGoalList -CodexHome $CodexHome
    if (-not $goalList.Available) {
        return [pscustomobject]@{ Ok = $false; Reason = "codex-goal-db: $($goalList.Reason)"; Synced = 0; Failed = 0; Total = 0 }
    }

    $health = Test-PostgreSqlHealth
    if (-not $health.Healthy) {
        return [pscustomobject]@{ Ok = $false; Reason = "postgresql not healthy: $($health.Reason)"; Synced = 0; Failed = 0; Total = @($goalList.Goals).Count }
    }

    $synced = 0
    $failed = 0
    foreach ($goal in @($goalList.Goals)) {
        $result = Set-CodexGoalProjectionRecord -Goal $goal
        if ($result.Ok) { $synced++ } else { $failed++ }
    }

    return [pscustomobject]@{
        Ok      = ($failed -eq 0)
        Reason  = if ($failed -eq 0) { "ok" } else { "$failed record(s) failed to sync" }
        Synced  = $synced
        Failed  = $failed
        Total   = @($goalList.Goals).Count
    }
}

function Get-CodexGoalProjection {
    <#
        codex_goal_projectionsから投影済みGoalを取得する（読み取り専用）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [string]$Status = ""
    )

    if ([string]::IsNullOrWhiteSpace($Status)) {
        $sql = "SELECT thread_id, goal_id, objective, status, token_budget, tokens_used, time_used_seconds, codex_updated_at_ms, synced_at FROM codex_goal_projections ORDER BY synced_at DESC;"
    }
    else {
        $sql = "SELECT thread_id, goal_id, objective, status, token_budget, tokens_used, time_used_seconds, codex_updated_at_ms, synced_at FROM codex_goal_projections WHERE status = {0} ORDER BY synced_at DESC;" -f (ConvertTo-PostgreSqlLiteral -Value $Status)
    }

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    return @($result.Output.Trim() -split "`n" | ForEach-Object {
        $fields = $_ -split '\|'
        [pscustomobject]@{
            ThreadId        = $fields[0]
            GoalId          = $fields[1]
            Objective       = $fields[2]
            Status          = $fields[3]
            TokenBudget     = $fields[4]
            TokensUsed      = $fields[5]
            TimeUsedSeconds = $fields[6]
            CodexUpdatedAtMs = $fields[7]
            SyncedAt        = $fields[8]
        }
    })
}

Export-ModuleMember -Function @(
    "Get-CodexGoalProjection",
    "Set-CodexGoalProjectionRecord",
    "Sync-CodexGoalProjection"
)
