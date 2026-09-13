Set-StrictMode -Version Latest

function Get-OrchestrationProjectRoot {
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    $path = $PSScriptRoot
    while ($path -and -not (Test-Path (Join-Path $path ".git"))) {
        $path = Split-Path $path -Parent
    }

    return $path
}

function New-OrchestrationId {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Pure in-memory GUID generation, not a system-changing operation.")]
    [OutputType([System.String])]
    param()

    return [guid]::NewGuid().ToString()
}

function Get-OrchestrationTimestamp {
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    return (Get-Date).ToUniversalTime().ToString("o")
}

function ConvertTo-PostgreSqlLiteral {
    <#
        SQL文字列リテラル用の最小エスケープ。単純なシングルクォート置換のみを行う。
        バックスラッシュエスケープには依存しない（standard_conforming_stringsを前提とする）。
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [AllowEmptyString()]
        [string]$Value = ""
    )

    $escaped = $Value -replace "'", "''"
    return "'$escaped'"
}

function ConvertTo-PostgreSqlJsonLiteral {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 20 -Compress
    return (ConvertTo-PostgreSqlLiteral -Value $json) + "::jsonb"
}

function Get-OrchestrationFallbackPath {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[a-z_]+$")]
        [string]$Kind,

        [string]$ProjectRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $ProjectRoot = Get-OrchestrationProjectRoot
    }

    $dir = Join-Path $ProjectRoot "logs/orchestration"
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    return Join-Path $dir "$Kind.jsonl"
}

function Add-OrchestrationFallbackRecord {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Append-only local fallback log write, not a destructive system change.")]
    param(
        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [hashtable]$Record,

        [string]$ProjectRoot = ""
    )

    $path = Get-OrchestrationFallbackPath -Kind $Kind -ProjectRoot $ProjectRoot
    $line = $Record | ConvertTo-Json -Depth 20 -Compress
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Get-OrchestrationFallbackRecord {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Kind,

        [string]$Id = "",
        [string]$ProjectRoot = ""
    )

    $path = Get-OrchestrationFallbackPath -Kind $Kind -ProjectRoot $ProjectRoot
    if (-not (Test-Path $path)) {
        return @()
    }

    $records = @(Get-Content -Path $path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $null -ne $_ })

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        return @($records | Where-Object { $_.id -eq $Id })
    }

    return $records
}

Export-ModuleMember -Function @(
    "Add-OrchestrationFallbackRecord",
    "ConvertTo-PostgreSqlJsonLiteral",
    "ConvertTo-PostgreSqlLiteral",
    "Get-OrchestrationFallbackPath",
    "Get-OrchestrationFallbackRecord",
    "Get-OrchestrationProjectRoot",
    "Get-OrchestrationTimestamp",
    "New-OrchestrationId"
)
