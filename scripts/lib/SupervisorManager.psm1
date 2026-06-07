Set-StrictMode -Version Latest

function Get-RegisteredProjectRoot {
    [CmdletBinding()]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $registered = $Config.PSObject.Properties["registeredProjects"]?.Value
    if ($null -ne $registered -and $registered.PSObject.Properties["roots"]?.Value) {
        return @($registered.roots | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    }

    if ($Config.PSObject.Properties["projectsDir"]?.Value) {
        return @($Config.projectsDir)
    }

    if ($env:HOME) {
        return @(Join-Path $env:HOME "Projects")
    }

    return @("/home/kensan/Projects")
}

function Get-RegisteredProjectCandidate {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $registered = $Config.PSObject.Properties["registeredProjects"]?.Value
    $maxCandidates = if ($null -ne $registered -and $registered.PSObject.Properties["maxCandidates"]?.Value) {
        [int]$registered.maxCandidates
    }
    else {
        80
    }
    $include = @(if ($null -ne $registered -and $registered.PSObject.Properties["include"]?.Value) { $registered.include })
    $exclude = @(if ($null -ne $registered -and $registered.PSObject.Properties["exclude"]?.Value) { $registered.exclude })
    $roots = @(Get-RegisteredProjectRoot -Config $Config)

    $projects = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        $expandedRoot = [System.Environment]::ExpandEnvironmentVariables($root)
        if (-not (Test-Path $expandedRoot)) {
            continue
        }

        $children = @(Get-ChildItem -Path $expandedRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^\.' } |
                Sort-Object Name)

        foreach ($child in $children) {
            if ($projects.Count -ge $maxCandidates) {
                break
            }
            if (@($include).Count -gt 0 -and $child.Name -notin $include) {
                continue
            }
            if ($child.Name -in $exclude) {
                continue
            }

            $projects.Add([pscustomobject]@{
                    name = $child.Name
                    path = $child.FullName
                    root = $expandedRoot
                })
        }
    }

    return @($projects)
}

function New-SupervisorManifest {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$ProjectName
    )

    $supervisor = $Config.PSObject.Properties["supervisor"]?.Value
    $mode = if ($null -ne $supervisor -and $supervisor.PSObject.Properties["mode"]?.Value) {
        "$($supervisor.mode)"
    }
    else {
        "cto-autonomous"
    }
    $humanDecisionRequired = if ($null -ne $supervisor -and $supervisor.PSObject.Properties["humanDecisionRequired"]?.Value) {
        @($supervisor.humanDecisionRequired)
    }
    else {
        @("final-choice", "merge", "release")
    }

    return [pscustomobject]@{
        schemaVersion            = "1.0.0"
        project                  = $ProjectName
        managedBy                = "Codex-StartUpTools-New-Linux"
        mode                     = $mode
        agentLoop                = @("monitor", "build", "verify", "improve")
        codexOnly                = $true
        sshEnabled               = $false
        humanDecisionRequired    = $humanDecisionRequired
        supervisorAppliedAt      = (Get-Date).ToString("o")
    }
}

function Set-SupervisorForProject {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by local supervisor bootstrap automation.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [object]$Config,

        [switch]$PreviewOnly
    )

    if (-not (Test-Path $ProjectPath)) {
        throw "プロジェクトディレクトリが見つかりません: $ProjectPath"
    }

    $projectName = Split-Path -Leaf $ProjectPath
    $manifest = New-SupervisorManifest -Config $Config -ProjectName $projectName
    $codexDir = Join-Path $ProjectPath ".codex"
    $manifestPath = Join-Path $codexDir "supervisor.json"

    if (-not $PreviewOnly) {
        if (-not (Test-Path $codexDir)) {
            New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
    }

    return [pscustomobject]@{
        project = $projectName
        path    = $ProjectPath
        target  = $manifestPath
        applied = -not $PreviewOnly
    }
}

function Set-SupervisorForRegisteredProjects {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [switch]$PreviewOnly,

        [string[]]$ProjectNames = @()
    )

    $supervisor = $Config.PSObject.Properties["supervisor"]?.Value
    if ($null -ne $supervisor -and $supervisor.PSObject.Properties["enabled"]?.Value -eq $false) {
        return @()
    }

    $projects = @(Get-RegisteredProjectCandidate -Config $Config)
    if (@($ProjectNames).Count -gt 0) {
        $nameSet = @{}
        foreach ($name in $ProjectNames) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $nameSet[$name] = $true
            }
        }
        $projects = @($projects | Where-Object { $nameSet.ContainsKey($_.name) })
    }

    return @($projects | ForEach-Object {
            Set-SupervisorForProject -ProjectPath $_.path -Config $Config -PreviewOnly:$PreviewOnly
        })
}

function Get-SupervisorStatusForProject {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [object]$Project
    )

    $projectName = if ($Project.PSObject.Properties["name"]?.Value) { "$($Project.name)" } else { Split-Path -Leaf "$($Project.path)" }
    $projectPath = "$($Project.path)"
    $manifestPath = Join-Path $projectPath ".codex/supervisor.json"
    $exists = Test-Path $manifestPath
    $manifest = $null
    $parseError = ""

    if ($exists) {
        try {
            $manifest = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $parseError = "$_"
        }
    }

    $managedBy = if ($manifest -and $manifest.PSObject.Properties["managedBy"]?.Value) { "$($manifest.managedBy)" } else { "" }
    $mode = if ($manifest -and $manifest.PSObject.Properties["mode"]?.Value) { "$($manifest.mode)" } else { "" }
    $appliedAt = if ($manifest -and $manifest.PSObject.Properties["supervisorAppliedAt"]?.Value) { "$($manifest.supervisorAppliedAt)" } else { "" }
    $codexOnly = if ($manifest -and $manifest.PSObject.Properties["codexOnly"]?.Value -ne $null) { [bool]$manifest.codexOnly } else { $false }
    $sshEnabled = if ($manifest -and $manifest.PSObject.Properties["sshEnabled"]?.Value -ne $null) { [bool]$manifest.sshEnabled } else { $false }

    $status = if (-not $exists) {
        "Missing"
    }
    elseif ($parseError) {
        "Invalid"
    }
    elseif ($managedBy -eq "Codex-StartUpTools-New-Linux" -and $codexOnly -and -not $sshEnabled) {
        "Managed"
    }
    else {
        "Foreign"
    }

    return [pscustomobject]@{
        project        = $projectName
        path           = $projectPath
        manifestPath   = $manifestPath
        status         = $status
        hasSupervisor  = $exists
        managedBy      = $managedBy
        mode           = $mode
        codexOnly      = $codexOnly
        sshEnabled     = $sshEnabled
        appliedAt      = $appliedAt
        parseError     = $parseError
    }
}

function Get-SupervisorReport {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $entries = @(Get-RegisteredProjectCandidate -Config $Config | ForEach-Object {
            Get-SupervisorStatusForProject -Project $_
        })

    $managed = @($entries | Where-Object { $_.status -eq "Managed" })
    $missing = @($entries | Where-Object { $_.status -eq "Missing" })
    $foreign = @($entries | Where-Object { $_.status -eq "Foreign" })
    $invalid = @($entries | Where-Object { $_.status -eq "Invalid" })

    return [pscustomobject]@{
        generatedAt  = (Get-Date).ToString("o")
        total        = $entries.Count
        managed      = $managed.Count
        missing      = $missing.Count
        foreign      = $foreign.Count
        invalid      = $invalid.Count
        entries      = @($entries)
    }
}

Export-ModuleMember -Function @(
    "Get-RegisteredProjectRoot",
    "Get-RegisteredProjectCandidate",
    "Get-SupervisorReport",
    "Get-SupervisorStatusForProject",
    "New-SupervisorManifest",
    "Set-SupervisorForProject",
    "Set-SupervisorForRegisteredProjects"
)
