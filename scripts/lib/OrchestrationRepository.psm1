Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "PostgreSqlStore.psm1")

function Add-OrchestrationTask {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$TaskType,

        [hashtable]$Payload = @{},

        [string]$Status = "pending",
        [string]$ProjectRoot = ""
    )

    $id = New-OrchestrationId
    $timestamp = Get-OrchestrationTimestamp

    $sql = "INSERT INTO orchestration_tasks (id, task_type, status, payload, created_at, updated_at) VALUES ({0}, {1}, {2}, {3}, {4}, {4});" -f `
        (ConvertTo-PostgreSqlLiteral -Value $id), `
        (ConvertTo-PostgreSqlLiteral -Value $TaskType), `
        (ConvertTo-PostgreSqlLiteral -Value $Status), `
        (ConvertTo-PostgreSqlJsonLiteral -InputObject $Payload), `
        (ConvertTo-PostgreSqlLiteral -Value $timestamp)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    $source = if ($result.Ok) { "postgresql" } else { "file_fallback" }

    if (-not $result.Ok) {
        Add-OrchestrationFallbackRecord -Kind "tasks" -ProjectRoot $ProjectRoot -Record @{
            id         = $id
            task_type  = $TaskType
            status     = $Status
            payload    = $Payload
            created_at = $timestamp
            updated_at = $timestamp
        }
    }

    return [pscustomobject]@{
        Id       = $id
        TaskType = $TaskType
        Status   = $Status
        Source   = $source
        Ok       = $true
    }
}

function Get-OrchestrationTask {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [string]$ProjectRoot = ""
    )

    $sql = "SELECT id, task_type, status, payload, created_at, updated_at FROM orchestration_tasks WHERE id = {0};" -f (ConvertTo-PostgreSqlLiteral -Value $Id)
    $result = Invoke-PostgreSqlCommand -Sql $sql

    if ($result.Ok -and -not [string]::IsNullOrWhiteSpace($result.Output)) {
        $fields = $result.Output.Trim() -split '\|'
        return [pscustomobject]@{
            Id        = $fields[0]
            TaskType  = $fields[1]
            Status    = $fields[2]
            Payload   = $fields[3]
            CreatedAt = $fields[4]
            UpdatedAt = $fields[5]
            Source    = "postgresql"
        }
    }

    $fallback = @(Get-OrchestrationFallbackRecord -Kind "tasks" -Id $Id -ProjectRoot $ProjectRoot) | Select-Object -Last 1
    if ($fallback) {
        return [pscustomobject]@{
            Id        = $fallback.id
            TaskType  = $fallback.task_type
            Status    = $fallback.status
            Payload   = $fallback.payload
            CreatedAt = $fallback.created_at
            UpdatedAt = $fallback.updated_at
            Source    = "file_fallback"
        }
    }

    return $null
}

function Set-OrchestrationTaskStatus {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Writes to the orchestration control-plane store, not a local host system change requiring ShouldProcess.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Status,

        [string]$ProjectRoot = ""
    )

    $timestamp = Get-OrchestrationTimestamp
    $sql = "UPDATE orchestration_tasks SET status = {0}, updated_at = {1} WHERE id = {2};" -f `
        (ConvertTo-PostgreSqlLiteral -Value $Status), `
        (ConvertTo-PostgreSqlLiteral -Value $timestamp), `
        (ConvertTo-PostgreSqlLiteral -Value $Id)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    $source = if ($result.Ok) { "postgresql" } else { "file_fallback" }

    if (-not $result.Ok) {
        Add-OrchestrationFallbackRecord -Kind "tasks" -ProjectRoot $ProjectRoot -Record @{
            id         = $Id
            status     = $Status
            updated_at = $timestamp
            event      = "status_update"
        }
    }

    return [pscustomobject]@{ Id = $Id; Status = $Status; Source = $source; Ok = $true }
}

function Add-OrchestrationRun {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,

        [string]$Status = "started",
        [hashtable]$Metadata = @{},
        [string]$ProjectRoot = ""
    )

    $id = New-OrchestrationId
    $timestamp = Get-OrchestrationTimestamp

    $sql = "INSERT INTO orchestration_runs (id, task_id, status, started_at, metadata, created_at) VALUES ({0}, {1}, {2}, {3}, {4}, {3});" -f `
        (ConvertTo-PostgreSqlLiteral -Value $id), `
        (ConvertTo-PostgreSqlLiteral -Value $TaskId), `
        (ConvertTo-PostgreSqlLiteral -Value $Status), `
        (ConvertTo-PostgreSqlLiteral -Value $timestamp), `
        (ConvertTo-PostgreSqlJsonLiteral -InputObject $Metadata)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    $source = if ($result.Ok) { "postgresql" } else { "file_fallback" }

    if (-not $result.Ok) {
        Add-OrchestrationFallbackRecord -Kind "runs" -ProjectRoot $ProjectRoot -Record @{
            id         = $id
            task_id    = $TaskId
            status     = $Status
            metadata   = $Metadata
            started_at = $timestamp
            created_at = $timestamp
        }
    }

    return [pscustomobject]@{ Id = $id; TaskId = $TaskId; Status = $Status; Source = $source; Ok = $true }
}

function Set-OrchestrationRunStatus {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Writes to the orchestration control-plane store, not a local host system change requiring ShouldProcess.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Status,

        [switch]$Ended,
        [string]$ProjectRoot = ""
    )

    $timestamp = Get-OrchestrationTimestamp
    $endedClause = if ($Ended) { ", ended_at = $(ConvertTo-PostgreSqlLiteral -Value $timestamp)" } else { "" }
    $sql = "UPDATE orchestration_runs SET status = {0}{1} WHERE id = {2};" -f `
        (ConvertTo-PostgreSqlLiteral -Value $Status), $endedClause, (ConvertTo-PostgreSqlLiteral -Value $Id)

    $result = Invoke-PostgreSqlCommand -Sql $sql
    $source = if ($result.Ok) { "postgresql" } else { "file_fallback" }

    if (-not $result.Ok) {
        Add-OrchestrationFallbackRecord -Kind "runs" -ProjectRoot $ProjectRoot -Record @{
            id       = $Id
            status   = $Status
            ended    = [bool]$Ended
            event    = "status_update"
            recorded = $timestamp
        }
    }

    return [pscustomobject]@{ Id = $Id; Status = $Status; Source = $source; Ok = $true }
}

Export-ModuleMember -Function @(
    "Add-OrchestrationRun",
    "Add-OrchestrationTask",
    "Get-OrchestrationTask",
    "Set-OrchestrationRunStatus",
    "Set-OrchestrationTaskStatus"
)
