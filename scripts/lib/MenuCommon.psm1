Set-StrictMode -Version Latest

$script:ValidTools = @('codex')
$script:ValidSortModes = @('success', 'timestamp', 'elapsed')

function ConvertTo-MenuRecentToolFilter {
    [CmdletBinding()]
    param(
        [string]$ToolFilter = ''
    )

    if ([string]::IsNullOrWhiteSpace($ToolFilter) -or $ToolFilter -eq 'all') {
        return ''
    }

    if ($ToolFilter -in $script:ValidTools) {
        return $ToolFilter
    }

    return ''
}

function ConvertTo-MenuRecentSortMode {
    [CmdletBinding()]
    param(
        [string]$SortMode = 'success'
    )

    if ($SortMode -in $script:ValidSortModes) {
        return $SortMode
    }

    return 'success'
}

function Get-MenuRecentFilterSummary {
    [CmdletBinding()]
    param(
        [string]$ToolFilter = '',
        [string]$SearchQuery = '',
        [string]$SortMode = 'success'
    )

    $normalizedTool = ConvertTo-MenuRecentToolFilter -ToolFilter $ToolFilter

    return [pscustomobject]@{
        tool   = if ([string]::IsNullOrWhiteSpace($normalizedTool)) { 'all' } else { $normalizedTool }
        search = if ([string]::IsNullOrWhiteSpace($SearchQuery)) { 'none' } else { $SearchQuery }
        sort   = ConvertTo-MenuRecentSortMode -SortMode $SortMode
    }
}

function Get-ValidToolNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:ValidTools
}

function Get-ValidSortModes {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:ValidSortModes
}

Export-ModuleMember -Function @(
    'ConvertTo-MenuRecentToolFilter',
    'ConvertTo-MenuRecentSortMode',
    'Get-MenuRecentFilterSummary',
    'Get-ValidToolNames',
    'Get-ValidSortModes'
)
