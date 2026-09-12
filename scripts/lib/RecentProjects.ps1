Set-StrictMode -Version Latest

function Get-RecentProject {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HistoryPath
    )

    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($HistoryPath)
    if (-not (Test-Path $expandedPath)) {
        return @()
    }

    try {
        $content = Get-Content -Path $expandedPath -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json

        if ($null -eq $data -or $null -eq $data.projects) {
            return @()
        }

        $normalized = @()
        foreach ($entry in @($data.projects)) {
            if ($entry -is [string]) {
                $normalized += [pscustomobject]@{
                    project   = $entry
                    tool      = $null
                    mode      = $null
                    timestamp = $null
                    result    = $null
                    elapsedMs = $null
                }
                continue
            }

            if ($entry.PSObject.Properties.Name -contains "project") {
                $tool = if ($entry.PSObject.Properties.Name -contains "tool") { "$($entry.tool)" } else { $null }
                $mode = if ($entry.PSObject.Properties.Name -contains "mode") { "$($entry.mode)" } else { $null }
                $timestamp = if ($entry.PSObject.Properties.Name -contains "timestamp") { "$($entry.timestamp)" } else { $null }

                $normalized += [pscustomobject]@{
                    project   = "$($entry.project)"
                    tool      = if ([string]::IsNullOrWhiteSpace($tool)) { $null } else { $tool }
                    mode      = if ([string]::IsNullOrWhiteSpace($mode)) { $null } else { $mode }
                    timestamp = if ([string]::IsNullOrWhiteSpace($timestamp)) { $null } else { $timestamp }
                    result    = if ($entry.PSObject.Properties.Name -contains "result" -and -not [string]::IsNullOrWhiteSpace("$($entry.result)")) { "$($entry.result)" } else { $null }
                    elapsedMs = if ($entry.PSObject.Properties.Name -contains "elapsedMs" -and $null -ne $entry.elapsedMs) { [int]$entry.elapsedMs } else { $null }
                }
            }
        }

        return @($normalized)
    }
    catch {
        Write-Warning "最近使用プロジェクト履歴の読み込みに失敗しました: $_"
        return @()
    }
}

function Update-RecentProject {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by unattended local automation.")]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectName,

        [ValidateSet("codex", "")]
        [string]$Tool = "",

        [ValidateSet("local", "")]
        [string]$Mode = "",

        [ValidateSet("success", "failure", "cancelled", "unknown", "")]
        [string]$Result = "",

        [Nullable[int]]$ElapsedMs = $null,

        [Parameter(Mandatory = $true)]
        [string]$HistoryPath,

        [int]$MaxHistory = 10
    )

    $expandedPath = [System.Environment]::ExpandEnvironmentVariables($HistoryPath)
    $directory = Split-Path $expandedPath -Parent
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $projects = [System.Collections.Generic.List[object]]::new()
    $existing = Get-RecentProject -HistoryPath $HistoryPath
    foreach ($project in $existing) {
        $sameProject = ($project.project -ceq $ProjectName)
        $sameTool = (([string]::IsNullOrWhiteSpace($Tool) -and [string]::IsNullOrWhiteSpace($project.tool)) -or ($project.tool -eq $Tool))
        $sameMode = (([string]::IsNullOrWhiteSpace($Mode) -and [string]::IsNullOrWhiteSpace($project.mode)) -or ($project.mode -eq $Mode))
        if (-not ($sameProject -and $sameTool -and $sameMode)) {
            $projects.Add($project)
        }
    }

    $projects.Insert(0, [pscustomobject]@{
        project   = $ProjectName
        tool      = if ([string]::IsNullOrWhiteSpace($Tool)) { $null } else { $Tool }
        mode      = if ([string]::IsNullOrWhiteSpace($Mode)) { $null } else { $Mode }
        timestamp = (Get-Date).ToString("o")
        result    = if ([string]::IsNullOrWhiteSpace($Result)) { $null } else { $Result }
        elapsedMs = if ($PSBoundParameters.ContainsKey("ElapsedMs") -and $null -ne $ElapsedMs) { [int]$ElapsedMs } else { $null }
    })

    if ($projects.Count -gt $MaxHistory) {
        $projects = [System.Collections.Generic.List[object]]($projects | Select-Object -First $MaxHistory)
    }

    try {
        $data = @{ projects = @($projects) }
        $json = $data | ConvertTo-Json -Depth 3
        Set-Content -Path $expandedPath -Value $json -Encoding UTF8
        Write-Host "[INFO]  最近使用プロジェクト更新: $ProjectName" -ForegroundColor Cyan
    }
    catch {
        Write-Warning "最近使用プロジェクト履歴の保存に失敗しました: $_"
    }
}

function Test-RecentProjectsEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    return ($null -ne $Config.recentProjects -and $Config.recentProjects.enabled -and -not [string]::IsNullOrWhiteSpace($Config.recentProjects.historyFile))
}
