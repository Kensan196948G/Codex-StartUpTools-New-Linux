Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "PostgreSqlStore.psm1")

function Add-OrchestrationAuditEvent {
    <#
        追記専用の監査イベント記録。Detailに秘密情報・接続文字列・資格情報を
        含めないこと（AGENTS.md/CLAUDE.md §8準拠）。呼び出し元が責任を持つ。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$TaskId = "",
        [string]$RunId = "",

        [Parameter(Mandatory)]
        [string]$EventType,

        [hashtable]$Detail = @{},
        [string]$ProjectRoot = ""
    )

    $timestamp = Get-OrchestrationTimestamp
    $id = New-OrchestrationId

    $sql = "INSERT INTO orchestration_audit_events (id, task_id, run_id, event_type, detail, occurred_at) VALUES ({0}, {1}, {2}, {3}, {4}, {5});" -f `
        (ConvertTo-PostgreSqlLiteral -Value $id), `
        $(if ([string]::IsNullOrWhiteSpace($TaskId)) { "NULL" } else { ConvertTo-PostgreSqlLiteral -Value $TaskId }), `
        $(if ([string]::IsNullOrWhiteSpace($RunId)) { "NULL" } else { ConvertTo-PostgreSqlLiteral -Value $RunId }), `
        (ConvertTo-PostgreSqlLiteral -Value $EventType), `
        (ConvertTo-PostgreSqlJsonLiteral -InputObject $Detail), `
        (ConvertTo-PostgreSqlLiteral -Value $timestamp)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    $source = if ($result.Ok) { "postgresql" } else { "file_fallback" }

    if (-not $result.Ok) {
        Add-OrchestrationFallbackRecord -Kind "audit_events" -ProjectRoot $ProjectRoot -Record @{
            id          = $id
            task_id     = $TaskId
            run_id      = $RunId
            event_type  = $EventType
            detail      = $Detail
            occurred_at = $timestamp
        }
    }

    return [pscustomobject]@{
        Id        = $id
        EventType = $EventType
        Source    = $source
        Ok        = $true
    }
}

function Get-OrchestrationAuditEvent {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [string]$TaskId = "",
        [int]$Limit = 100,
        [string]$ProjectRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        $sql = "SELECT id, task_id, run_id, event_type, detail, occurred_at FROM orchestration_audit_events ORDER BY occurred_at DESC LIMIT {0};" -f $Limit
    }
    else {
        $sql = "SELECT id, task_id, run_id, event_type, detail, occurred_at FROM orchestration_audit_events WHERE task_id = {0} ORDER BY occurred_at DESC LIMIT {1};" -f `
            (ConvertTo-PostgreSqlLiteral -Value $TaskId), $Limit
    }

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if ($result.Ok) {
        if ([string]::IsNullOrWhiteSpace($result.Output)) {
            return @()
        }

        return @($result.Output.Trim() -split "`n" | ForEach-Object {
            $fields = $_ -split '\|'
            [pscustomobject]@{
                Id         = $fields[0]
                TaskId     = $fields[1]
                RunId      = $fields[2]
                EventType  = $fields[3]
                Detail     = $fields[4]
                OccurredAt = $fields[5]
                Source     = "postgresql"
            }
        })
    }

    $fallback = @(Get-OrchestrationFallbackRecord -Kind "audit_events" -ProjectRoot $ProjectRoot)
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $fallback = @($fallback | Where-Object { $_.task_id -eq $TaskId })
    }

    return @($fallback | Select-Object -Last $Limit | ForEach-Object {
        [pscustomobject]@{
            Id         = $_.id
            TaskId     = $_.task_id
            RunId      = $_.run_id
            EventType  = $_.event_type
            Detail     = $_.detail
            OccurredAt = $_.occurred_at
            Source     = "file_fallback"
        }
    })
}

Export-ModuleMember -Function @(
    "Add-OrchestrationAuditEvent",
    "Get-OrchestrationAuditEvent"
)
