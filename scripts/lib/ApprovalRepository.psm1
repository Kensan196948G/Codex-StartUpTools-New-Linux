Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "PostgreSqlStore.psm1")

function Add-OrchestrationApproval {
    <#
        Human Gate判断の記録。AGENTS.md/CLAUDE.md §7・§11のHuman Gate対象操作を
        承認・却下した際の監査証跡として使う。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$RunId = "",

        [Parameter(Mandatory)]
        [string]$Gate,

        [Parameter(Mandatory)]
        [ValidateSet("approved", "rejected")]
        [string]$Decision,

        [string]$DecidedBy = "",
        [string]$Reason = "",
        [string]$ProjectRoot = ""
    )

    $id = New-OrchestrationId
    $timestamp = Get-OrchestrationTimestamp

    $sql = "INSERT INTO orchestration_approvals (id, run_id, gate, decision, decided_by, reason, decided_at) VALUES ({0}, {1}, {2}, {3}, {4}, {5}, {6});" -f `
        (ConvertTo-PostgreSqlLiteral -Value $id), `
        $(if ([string]::IsNullOrWhiteSpace($RunId)) { "NULL" } else { ConvertTo-PostgreSqlLiteral -Value $RunId }), `
        (ConvertTo-PostgreSqlLiteral -Value $Gate), `
        (ConvertTo-PostgreSqlLiteral -Value $Decision), `
        (ConvertTo-PostgreSqlLiteral -Value $DecidedBy), `
        (ConvertTo-PostgreSqlLiteral -Value $Reason), `
        (ConvertTo-PostgreSqlLiteral -Value $timestamp)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    $source = if ($result.Ok) { "postgresql" } else { "file_fallback" }

    if (-not $result.Ok) {
        Add-OrchestrationFallbackRecord -Kind "approvals" -ProjectRoot $ProjectRoot -Record @{
            id         = $id
            run_id     = $RunId
            gate       = $Gate
            decision   = $Decision
            decided_by = $DecidedBy
            reason     = $Reason
            decided_at = $timestamp
        }
    }

    return [pscustomobject]@{
        Id       = $id
        RunId    = $RunId
        Gate     = $Gate
        Decision = $Decision
        Source   = $source
        Ok       = $true
    }
}

function Get-OrchestrationApproval {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [string]$RunId = "",
        [string]$ProjectRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $sql = "SELECT id, run_id, gate, decision, decided_by, reason, decided_at FROM orchestration_approvals ORDER BY decided_at DESC LIMIT 100;"
    }
    else {
        $sql = "SELECT id, run_id, gate, decision, decided_by, reason, decided_at FROM orchestration_approvals WHERE run_id = {0} ORDER BY decided_at DESC;" -f (ConvertTo-PostgreSqlLiteral -Value $RunId)
    }

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if ($result.Ok) {
        if ([string]::IsNullOrWhiteSpace($result.Output)) {
            return @()
        }

        return @($result.Output.Trim() -split "`n" | ForEach-Object {
            $fields = $_ -split '\|'
            [pscustomobject]@{
                Id        = $fields[0]
                RunId     = $fields[1]
                Gate      = $fields[2]
                Decision  = $fields[3]
                DecidedBy = $fields[4]
                Reason    = $fields[5]
                DecidedAt = $fields[6]
                Source    = "postgresql"
            }
        })
    }

    $fallback = @(Get-OrchestrationFallbackRecord -Kind "approvals" -ProjectRoot $ProjectRoot)
    if (-not [string]::IsNullOrWhiteSpace($RunId)) {
        $fallback = @($fallback | Where-Object { $_.run_id -eq $RunId })
    }

    return @($fallback | ForEach-Object {
        [pscustomobject]@{
            Id        = $_.id
            RunId     = $_.run_id
            Gate      = $_.gate
            Decision  = $_.decision
            DecidedBy = $_.decided_by
            Reason    = $_.reason
            DecidedAt = $_.decided_at
            Source    = "file_fallback"
        }
    })
}

function Request-OrchestrationHumanApproval {
    <#
        Human Gate承認待ち（decision='pending'）を作成する。
        AGENTS.md/CLAUDE.md §7 Mandatory stop conditions、および
        supervisor.jsonのhumanDecisionRequired対象操作の実行前に呼ぶ想定。
        PostgreSQL未接続時はOk=$falseを返す（承認待ち状態は制御プレーンDB必須の
        機能とし、File Fallbackでの疑似承認は行わない＝安全側に倒す）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$RunId = "",

        [Parameter(Mandatory)]
        [string]$Gate,

        [string]$Reason = ""
    )

    $id = New-OrchestrationId

    $sql = "INSERT INTO orchestration_approvals (id, run_id, gate, decision, reason, requested_at) VALUES ({0}, {1}, {2}, 'pending', {3}, now());" -f `
        (ConvertTo-PostgreSqlLiteral -Value $id), `
        $(if ([string]::IsNullOrWhiteSpace($RunId)) { "NULL" } else { ConvertTo-PostgreSqlLiteral -Value $RunId }), `
        (ConvertTo-PostgreSqlLiteral -Value $Gate), `
        (ConvertTo-PostgreSqlLiteral -Value $Reason)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $result.Reason; Id = $null }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "pending"; Id = $id; Gate = $Gate }
}

function Resolve-OrchestrationHumanGateDecision {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet("approved", "rejected")]
        [string]$Decision,

        [string]$DecidedBy = "",
        [string]$Reason = ""
    )

    $sql = "UPDATE orchestration_approvals SET decision = {0}, decided_by = {1}, decided_at = now()" -f `
        (ConvertTo-PostgreSqlLiteral -Value $Decision), (ConvertTo-PostgreSqlLiteral -Value $DecidedBy)
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $sql += ", reason = {0}" -f (ConvertTo-PostgreSqlLiteral -Value $Reason)
    }
    $sql += " WHERE id = {0} AND decision = 'pending' RETURNING id;" -f (ConvertTo-PostgreSqlLiteral -Value $Id)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $result.Reason; Updated = $false }
    }

    $updated = -not [string]::IsNullOrWhiteSpace($result.Output)
    return [pscustomobject]@{ Ok = $true; Reason = if ($updated) { "ok" } else { "not found or already decided" }; Updated = $updated }
}

function Approve-OrchestrationHumanGate {
    <#
        承認待ち（pending）のHuman Gateを承認済みにする。
        「現在の質問に対するユーザーの明示的な回答だけを有効とする」
        （AGENTS.md/CLAUDE.md §6）方針に従い、呼び出し元がユーザーの明示回答を
        得たうえで呼ぶこと。この関数自体はユーザー確認を代行しない。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [string]$DecidedBy = "",
        [string]$Reason = ""
    )

    return (Resolve-OrchestrationHumanGateDecision -Id $Id -Decision "approved" -DecidedBy $DecidedBy -Reason $Reason)
}

function Deny-OrchestrationHumanGate {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [string]$DecidedBy = "",
        [string]$Reason = ""
    )

    return (Resolve-OrchestrationHumanGateDecision -Id $Id -Decision "rejected" -DecidedBy $DecidedBy -Reason $Reason)
}

function Get-PendingOrchestrationHumanApproval {
    <#
        承認待ち（decision='pending'）のHuman Gate一覧を取得する（読み取り専用）。
        PostgreSQL未接続時は空配列を返す（Request側もFile Fallbackを持たないため、
        未接続時にpendingが存在することはない）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param()

    $sql = "SELECT id, run_id, gate, reason, requested_at FROM orchestration_approvals WHERE decision = 'pending' ORDER BY requested_at ASC;"
    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    return @($result.Output.Trim() -split "`n" | ForEach-Object {
        $fields = $_ -split '\|'
        [pscustomobject]@{ Id = $fields[0]; RunId = $fields[1]; Gate = $fields[2]; Reason = $fields[3]; RequestedAt = $fields[4] }
    })
}

Export-ModuleMember -Function @(
    "Add-OrchestrationApproval",
    "Approve-OrchestrationHumanGate",
    "Deny-OrchestrationHumanGate",
    "Get-OrchestrationApproval",
    "Get-PendingOrchestrationHumanApproval",
    "Request-OrchestrationHumanApproval"
)
