Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "PostgreSqlStore.psm1")

function Get-OrchestrationWorkerId {
    <#
        既定のWorker識別子。呼び出し元が明示指定しない場合のフォールバック。
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    $host_ = try { [System.Net.Dns]::GetHostName() } catch { "unknown-host" }
    return "{0}-{1}" -f $host_, $PID
}

function Get-NextOrchestrationTask {
    <#
        優先度(priority DESC) → 作成日時(created_at ASC)の順でpendingタスクを1件
        アトミックにリースする。他Workerとの競合はFOR UPDATE SKIP LOCKEDで回避する
        （PostgreSQL未接続時はOk=$falseを返し、呼び出し元はFile Fallbackキューを
        持たない設計とする＝Task Queueは制御プレーンDB必須機能）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [string]$Worker = "",
        [int]$LeaseSeconds = 300
    )

    if ([string]::IsNullOrWhiteSpace($Worker)) {
        $Worker = Get-OrchestrationWorkerId
    }
    $leaseSecondsInt = [int]$LeaseSeconds

    $sql = @"
UPDATE orchestration_tasks
SET status = 'running',
    leased_until = now() + interval '$leaseSecondsInt seconds',
    leased_by = {0},
    updated_at = now()
WHERE id = (
    SELECT id FROM orchestration_tasks
    WHERE status = 'pending' AND (leased_until IS NULL OR leased_until < now())
    ORDER BY priority DESC, created_at ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
RETURNING id, task_type, payload;
"@ -f (ConvertTo-PostgreSqlLiteral -Value $Worker)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $result.Reason; Task = $null }
    }

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return [pscustomobject]@{ Ok = $true; Reason = "no pending task"; Task = $null }
    }

    $fields = $result.Output.Trim() -split '\|'
    return [pscustomobject]@{
        Ok     = $true
        Reason = "leased"
        Task   = [pscustomobject]@{
            Id       = $fields[0]
            TaskType = $fields[1]
            Payload  = $fields[2]
            Worker   = $Worker
        }
    }
}

function Send-OrchestrationTaskHeartbeat {
    <#
        リース保持中のタスクのリース期限を延長する（Heartbeat）。
        Workerが一致しない場合は更新されない（0件更新=Ok=$true, Updated=$false）。
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Writes to the orchestration control-plane store, not a local host system change requiring ShouldProcess.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Worker,

        [int]$LeaseSeconds = 300
    )

    $leaseSecondsInt = [int]$LeaseSeconds
    $sql = "UPDATE orchestration_tasks SET leased_until = now() + interval '$leaseSecondsInt seconds' WHERE id = {0} AND leased_by = {1} AND status = 'running' RETURNING id;" -f `
        (ConvertTo-PostgreSqlLiteral -Value $Id), (ConvertTo-PostgreSqlLiteral -Value $Worker)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $result.Reason; Updated = $false }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok"; Updated = (-not [string]::IsNullOrWhiteSpace($result.Output)) }
}

function Complete-OrchestrationTask {
    <#
        リース保持中のタスクを完了させ、リース情報をクリアする。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Worker,

        [string]$Status = "completed"
    )

    $sql = "UPDATE orchestration_tasks SET status = {0}, leased_until = NULL, leased_by = NULL, updated_at = now() WHERE id = {1} AND leased_by = {2} RETURNING id;" -f `
        (ConvertTo-PostgreSqlLiteral -Value $Status), (ConvertTo-PostgreSqlLiteral -Value $Id), (ConvertTo-PostgreSqlLiteral -Value $Worker)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $result.Reason; Updated = $false }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok"; Updated = (-not [string]::IsNullOrWhiteSpace($result.Output)) }
}

function Get-StaleOrchestrationTask {
    <#
        リース期限切れ(running状態のままleased_untilが過去)のタスクを取得する
        （読み取り専用。回収はReset-StaleOrchestrationTaskで行う）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param()

    $sql = "SELECT id, task_type, leased_by, leased_until FROM orchestration_tasks WHERE status = 'running' AND leased_until IS NOT NULL AND leased_until < now();"
    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    return @($result.Output.Trim() -split "`n" | ForEach-Object {
        $fields = $_ -split '\|'
        [pscustomobject]@{ Id = $fields[0]; TaskType = $fields[1]; LeasedBy = $fields[2]; LeasedUntil = $fields[3] }
    })
}

function Reset-StaleOrchestrationTask {
    <#
        リース期限切れのタスクをpendingへ戻し、再取得可能にする（Stale Run回収）。
        Retry回数の上限管理はPhase 4以降の対象（本関数は無条件でpendingへ戻す）。
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Writes to the orchestration control-plane store, not a local host system change requiring ShouldProcess.")]
    [OutputType([System.Object])]
    param()

    $sql = "UPDATE orchestration_tasks SET status = 'pending', leased_until = NULL, leased_by = NULL, updated_at = now() WHERE status = 'running' AND leased_until IS NOT NULL AND leased_until < now() RETURNING id;"
    $result = Invoke-PostgreSqlCommand -Sql $sql
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $result.Reason; Recovered = 0 }
    }

    $count = if ([string]::IsNullOrWhiteSpace($result.Output)) { 0 } else { @($result.Output.Trim() -split "`n").Count }
    return [pscustomobject]@{ Ok = $true; Reason = "ok"; Recovered = $count }
}

Export-ModuleMember -Function @(
    "Complete-OrchestrationTask",
    "Get-NextOrchestrationTask",
    "Get-OrchestrationWorkerId",
    "Get-StaleOrchestrationTask",
    "Reset-StaleOrchestrationTask",
    "Send-OrchestrationTaskHeartbeat"
)
