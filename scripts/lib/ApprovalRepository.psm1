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

Export-ModuleMember -Function @(
    "Add-OrchestrationApproval",
    "Get-OrchestrationApproval"
)
