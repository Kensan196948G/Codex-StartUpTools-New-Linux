#!/usr/bin/env pwsh
# ============================================================
# Invoke-CodexGoal.ps1 — Codex ネイティブ Goal の非対話 CLI
#
# 役割:
#   `codex exec` に `--goal` が無いため、cron / CI / Supervisor から
#   Codex ネイティブ Goal を扱う入口を提供する。
#   判定・RPC は scripts/lib/CodexGoalClient.psm1 に集約し、本ファイルは薄い CLI に留める。
#
# 使い方:
#   Invoke-CodexGoal.ps1 -Action validate -Template <goals/*.md>   # 抽出と 4,000 字検証のみ
#   Invoke-CodexGoal.ps1 -Action start    -Template <goals/*.md>   # 新規スレッド + Goal 設定
#   Invoke-CodexGoal.ps1 -Action run      -Template <goals/*.md>   # 終端 status まで外部駆動
#   Invoke-CodexGoal.ps1 -Action set      -ThreadId <id> -Objective "<text>"
#   Invoke-CodexGoal.ps1 -Action get      -ThreadId <id>
#   Invoke-CodexGoal.ps1 -Action clear    -ThreadId <id>
#   Invoke-CodexGoal.ps1 -Action list                       # goals DB の Goal 一覧
#
#   -DryRun : objective を解決・検証して表示するだけ (RPC を呼ばない)
#
# 終了コード:
#   0 成功 / 1 引数・実行エラー / 2 objective が不正 (空 or 4,000 字超過)
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("validate", "start", "run", "set", "get", "clear", "list")]
    [string]$Action,

    [string]$Template,
    [string]$Objective,
    [string]$ThreadId,
    [int64]$TokenBudget,
    [string]$WorkingDirectory,
    [string]$CodexCommand = "codex",
    [int]$MaxTurns = 20,
    [int]$MaxMinutes = 120,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "lib/CodexGoalClient.psm1"
Import-Module $modulePath -Force

function Resolve-GoalObjective {
    param([string]$TemplatePath, [AllowEmptyString()][string]$ObjectiveText, [switch]$HasObjective)

    # -Objective が明示指定されていれば (空文字でも) それを検証対象にする。
    # 空文字を「未指定」として扱うと objective-empty ではなく汎用の usage エラーになり、
    # 原因が分かりにくくなるため。
    if ($HasObjective) { return $ObjectiveText }
    if (-not $TemplatePath) {
        throw "-Objective または -Template のいずれかが必要です。"
    }

    return Get-CodexGoalObjectiveFromTemplate -Path $TemplatePath
}

$script:HasObjectiveArg = $PSBoundParameters.ContainsKey("Objective")

try {
    switch ($Action) {
        "validate" {
            $resolved = Resolve-GoalObjective -TemplatePath $Template -ObjectiveText $Objective -HasObjective:$script:HasObjectiveArg
            $check = Test-CodexGoalObjective -Objective $resolved
            if (-not $check.Valid) {
                [Console]::Error.WriteLine("objective が不正です: $($check.Reason) (length=$($check.Length), max=$(Get-CodexGoalObjectiveMaxLength))")
                exit 2
            }
            Write-Output "OK objective length=$($check.Length) max=$(Get-CodexGoalObjectiveMaxLength)"
            exit 0
        }

        "list" {
            $result = Get-CodexGoalList
            if (-not $result.Available) {
                Write-Output "goal list unavailable: $($result.Reason) ($($result.DatabasePath))"
                exit 1
            }
            if ($result.Goals.Count -eq 0) {
                Write-Output "no goals"
                exit 0
            }
            $result.Goals | Select-Object ThreadId, Status, TokensUsed, TimeUsedSeconds, @{
                Name = "Objective"; Expression = { if ($_.Objective.Length -gt 60) { $_.Objective.Substring(0, 60) + "..." } else { $_.Objective } }
            } | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
            exit 0
        }

        "get" {
            if (-not $ThreadId) { throw "-Action get には -ThreadId が必要です。" }
            $goal = Get-CodexThreadGoal -ThreadId $ThreadId -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory
            if ($null -eq $goal) {
                Write-Output "no goal for thread $ThreadId"
                exit 0
            }
            $goal | ConvertTo-Json -Depth 6
            exit 0
        }

        "clear" {
            if (-not $ThreadId) { throw "-Action clear には -ThreadId が必要です。" }
            if ($DryRun) {
                Write-Output "[dry-run] clear goal for thread $ThreadId"
                exit 0
            }
            $cleared = Clear-CodexThreadGoal -ThreadId $ThreadId -CodexCommand $CodexCommand -WorkingDirectory $WorkingDirectory
            Write-Output "cleared=$cleared thread=$ThreadId"
            exit 0
        }

        "set" {
            if (-not $ThreadId) { throw "-Action set には -ThreadId が必要です。" }
            $resolved = Resolve-GoalObjective -TemplatePath $Template -ObjectiveText $Objective -HasObjective:$script:HasObjectiveArg
            $check = Test-CodexGoalObjective -Objective $resolved
            if (-not $check.Valid) {
                [Console]::Error.WriteLine("objective が不正です: $($check.Reason) (length=$($check.Length), max=$(Get-CodexGoalObjectiveMaxLength))")
                exit 2
            }
            if ($DryRun) {
                Write-Output "[dry-run] set goal thread=$ThreadId length=$($check.Length)"
                exit 0
            }

            $setArgs = @{
                ThreadId         = $ThreadId
                Objective        = $resolved
                CodexCommand     = $CodexCommand
                WorkingDirectory = $WorkingDirectory
            }
            if ($PSBoundParameters.ContainsKey("TokenBudget")) { $setArgs["TokenBudget"] = $TokenBudget }

            (Set-CodexThreadGoal @setArgs) | ConvertTo-Json -Depth 6
            exit 0
        }

        "start" {
            $resolved = Resolve-GoalObjective -TemplatePath $Template -ObjectiveText $Objective -HasObjective:$script:HasObjectiveArg
            $check = Test-CodexGoalObjective -Objective $resolved
            if (-not $check.Valid) {
                [Console]::Error.WriteLine("objective が不正です: $($check.Reason) (length=$($check.Length), max=$(Get-CodexGoalObjectiveMaxLength))")
                exit 2
            }
            if ($DryRun) {
                Write-Output "[dry-run] start goal length=$($check.Length)"
                exit 0
            }

            $startArgs = @{
                Objective        = $resolved
                CodexCommand     = $CodexCommand
                WorkingDirectory = $WorkingDirectory
            }
            if ($PSBoundParameters.ContainsKey("TokenBudget")) { $startArgs["TokenBudget"] = $TokenBudget }

            $run = Start-CodexGoalRun @startArgs
            Write-Output "thread=$($run.ThreadId)"
            $run.Goal | ConvertTo-Json -Depth 6
            Write-Output "Goal を登録しました。app-server は自動継続しないため、駆動には -Action run を使うか、"
            Write-Output "codex resume $($run.ThreadId) でスレッドへ接続してください。"
            exit 0
        }

        "run" {
            $resolved = Resolve-GoalObjective -TemplatePath $Template -ObjectiveText $Objective -HasObjective:$script:HasObjectiveArg
            $check = Test-CodexGoalObjective -Objective $resolved
            if (-not $check.Valid) {
                [Console]::Error.WriteLine("objective が不正です: $($check.Reason) (length=$($check.Length), max=$(Get-CodexGoalObjectiveMaxLength))")
                exit 2
            }
            if ($DryRun) {
                Write-Output "[dry-run] run goal length=$($check.Length) maxTurns=$MaxTurns maxMinutes=$MaxMinutes"
                exit 0
            }

            $runArgs = @{
                Objective        = $resolved
                CodexCommand     = $CodexCommand
                WorkingDirectory = $WorkingDirectory
                MaxTurns         = $MaxTurns
                MaxMinutes       = $MaxMinutes
                OnEvent          = {
                    param($r)
                    Write-Output ("  turn={0} completed={1} status={2} tokens={3}" -f $r.Turn, $r.TurnCompleted, $r.GoalStatus, $r.TokensUsed)
                }
            }
            if ($PSBoundParameters.ContainsKey("TokenBudget")) { $runArgs["TokenBudget"] = $TokenBudget }

            $result = Invoke-CodexGoalRun @runArgs
            Write-Output "thread=$($result.ThreadId)"
            Write-Output "finalStatus=$($result.FinalStatus) stopReason=$($result.StopReason) turns=$($result.Turns.Count)"
            if ($result.Goal) { $result.Goal | ConvertTo-Json -Depth 6 }
            exit 0
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
