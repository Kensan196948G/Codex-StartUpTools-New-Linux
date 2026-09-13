Set-StrictMode -Version Latest

$script:PSScriptRootLocal = $PSScriptRoot
Import-Module (Join-Path $script:PSScriptRootLocal "OrchestrationCommon.psm1")
Import-Module (Join-Path $script:PSScriptRootLocal "PostgreSqlStore.psm1")

function Get-OrchestrationMigrationFile {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [string]$MigrationsDir = ""
    )

    if ([string]::IsNullOrWhiteSpace($MigrationsDir)) {
        $MigrationsDir = Join-Path (Get-OrchestrationProjectRoot) "db/migrations"
    }

    $files = Get-ChildItem -Path $MigrationsDir -Filter "*.sql" -ErrorAction SilentlyContinue | Sort-Object Name

    return @($files | ForEach-Object {
        [pscustomobject]@{
            Version = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            Path    = $_.FullName
        }
    })
}

function Get-OrchestrationAppliedMigration {
    <#
        戻り値: [pscustomobject]@{ Ok; Versions }。
        PowerShellは関数のreturnで空配列を渡すと呼び出し元で$nullにアンラップ
        されるため、「接続不可（Ok=$false）」と「未適用0件（Ok=$true,Versions=@()）」
        を区別できるよう、常に構造化オブジェクトで返す。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param()

    $existsCheck = Invoke-PostgreSqlCommand -Sql "SELECT to_regclass('public.schema_migrations') IS NOT NULL;"
    if (-not $existsCheck.Ok) {
        return [pscustomobject]@{ Ok = $false; Versions = @() }
    }

    if ($existsCheck.Output.Trim() -ne "t") {
        return [pscustomobject]@{ Ok = $true; Versions = @() }
    }

    $listResult = Invoke-PostgreSqlCommand -Sql "SELECT version FROM schema_migrations ORDER BY version;"
    if (-not $listResult.Ok) {
        return [pscustomobject]@{ Ok = $false; Versions = @() }
    }

    if ([string]::IsNullOrWhiteSpace($listResult.Output)) {
        return [pscustomobject]@{ Ok = $true; Versions = @() }
    }

    $versions = @($listResult.Output.Trim() -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject]@{ Ok = $true; Versions = $versions }
}

function Invoke-OrchestrationMigrationFile {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$Version
    )

    $sql = Get-Content -Path $FilePath -Raw -Encoding UTF8
    # migrationは冪等でない可能性があるため再試行は行わない（1回のみ）。
    $result = Invoke-PostgreSqlCommand -Sql $sql -TimeoutSeconds 30 -MaxRetry 1
    if (-not $result.Ok) {
        return [pscustomobject]@{ Ok = $false; Version = $Version; Reason = $result.Reason }
    }

    $recordSql = "INSERT INTO schema_migrations (version) VALUES ({0}) ON CONFLICT (version) DO NOTHING;" -f (ConvertTo-PostgreSqlLiteral -Value $Version)
    $recordResult = Invoke-PostgreSqlCommand -Sql $recordSql -MaxRetry 1
    if (-not $recordResult.Ok) {
        return [pscustomobject]@{ Ok = $false; Version = $Version; Reason = "applied but failed to record schema_migrations: $($recordResult.Reason)" }
    }

    return [pscustomobject]@{ Ok = $true; Version = $Version; Reason = "applied" }
}

function Invoke-OrchestrationMigration {
    <#
        db/migrations/*.sql を version 昇順で未適用分のみ適用する。
        additiveかつ後方互換なmigrationのみを想定し、破壊的変更は含めない
        （AGENTS.md/CLAUDE.md §11 準拠）。
    #>
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [switch]$DryRun
    )

    $health = Test-PostgreSqlHealth
    if (-not $health.Healthy) {
        return [pscustomobject]@{ Ok = $false; Reason = "postgresql not healthy: $($health.Reason)"; Applied = @(); Pending = @() }
    }

    $files = Get-OrchestrationMigrationFile
    $appliedResult = Get-OrchestrationAppliedMigration
    if (-not $appliedResult.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = "failed to read schema_migrations state"; Applied = @(); Pending = @() }
    }
    $applied = $appliedResult.Versions

    $pending = @($files | Where-Object { $_.Version -notin $applied })

    $pendingVersions = @($pending | ForEach-Object { $_.Version })

    if ($DryRun) {
        return [pscustomobject]@{ Ok = $true; Reason = "dry-run"; Applied = @($applied); Pending = $pendingVersions }
    }

    $newlyApplied = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $pending) {
        $result = Invoke-OrchestrationMigrationFile -FilePath $file.Path -Version $file.Version
        if (-not $result.Ok) {
            return [pscustomobject]@{
                Ok      = $false
                Reason  = "failed applying $($file.Version): $($result.Reason)"
                Applied = @($newlyApplied)
                Pending = @($pendingVersions | Where-Object { $_ -notin $newlyApplied })
            }
        }
        $newlyApplied.Add($file.Version)
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok"; Applied = @($newlyApplied); Pending = @() }
}

Export-ModuleMember -Function @(
    "Get-OrchestrationAppliedMigration",
    "Get-OrchestrationMigrationFile",
    "Invoke-OrchestrationMigration",
    "Invoke-OrchestrationMigrationFile"
)
