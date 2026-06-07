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

function Get-RegisteredProjectCategoryMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $map = @{}
    $registered = $Config.PSObject.Properties["registeredProjects"]?.Value
    $categories = if ($null -ne $registered -and $registered.PSObject.Properties["categories"]?.Value) {
        $registered.categories
    }
    else {
        $null
    }

    if ($null -eq $categories) {
        return $map
    }

    foreach ($property in @($categories.PSObject.Properties)) {
        foreach ($projectName in @($property.Value)) {
            if (-not [string]::IsNullOrWhiteSpace("$projectName") -and -not $map.ContainsKey("$projectName")) {
                $map["$projectName"] = $property.Name
            }
        }
    }

    return $map
}

function Get-RegisteredProjectCandidateInventory {
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
    $categoryMap = Get-RegisteredProjectCategoryMap -Config $Config

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

            $category = if ($categoryMap.ContainsKey($child.Name)) { $categoryMap[$child.Name] } else { "uncategorized" }
            $isExcluded = $child.Name -in $exclude
            $projects.Add([pscustomobject]@{
                    name     = $child.Name
                    path     = $child.FullName
                    root     = $expandedRoot
                    excluded = $isExcluded
                    status   = if ($isExcluded) { "excluded" } else { "active" }
                    category = $category
                })
        }
    }

    return @($projects)
}

function Set-RegisteredProjectExclusion {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by interactive local config management after explicit user input.")]
    [OutputType([System.String[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [ValidateSet("exclude", "restore")]
        [string]$Operation,

        [string[]]$ProjectNames = @()
    )

    $registered = $Config.PSObject.Properties["registeredProjects"]?.Value
    if ($null -eq $registered) {
        throw "registeredProjects 設定が見つかりません。"
    }

    $current = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(if ($registered.PSObject.Properties["exclude"]?.Value) { $registered.exclude })) {
        if (-not [string]::IsNullOrWhiteSpace("$name") -and "$name" -notin $current) {
            $current.Add("$name")
        }
    }

    foreach ($name in @($ProjectNames)) {
        if ([string]::IsNullOrWhiteSpace("$name")) {
            continue
        }

        if ($Operation -eq "exclude") {
            if ("$name" -notin $current) {
                $current.Add("$name")
            }
        }
        else {
            if ("$name" -in $current) {
                $current.Remove("$name") | Out-Null
            }
        }
    }

    $updated = @($current | Sort-Object)
    $registered | Add-Member -NotePropertyName "exclude" -NotePropertyValue $updated -Force
    return $updated
}

function Set-RegisteredProjectCategory {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by interactive local config management after explicit user input.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$CategoryName,

        [string[]]$ProjectNames = @()
    )

    $category = $CategoryName.Trim()
    if ([string]::IsNullOrWhiteSpace($category)) {
        throw "カテゴリ名が空です。"
    }

    $registered = $Config.PSObject.Properties["registeredProjects"]?.Value
    if ($null -eq $registered) {
        throw "registeredProjects 設定が見つかりません。"
    }

    if (-not $registered.PSObject.Properties["categories"]?.Value) {
        $registered | Add-Member -NotePropertyName "categories" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $categories = $registered.categories
    $targetNames = @($ProjectNames | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { "$_" })

    foreach ($property in @($categories.PSObject.Properties)) {
        $remaining = @($property.Value | Where-Object { "$_" -notin $targetNames } | Sort-Object)
        $categories | Add-Member -NotePropertyName $property.Name -NotePropertyValue $remaining -Force
    }

    $current = @(if ($categories.PSObject.Properties[$category]) { $categories.PSObject.Properties[$category].Value })
    $updated = @($current + $targetNames | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Sort-Object -Unique)
    $categories | Add-Member -NotePropertyName $category -NotePropertyValue $updated -Force

    return [pscustomobject]@{
        category = $category
        projects = $updated
    }
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

function Convert-SupervisorDiffValue {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "(missing)"
    }

    if ($Value -is [System.Array]) {
        return (@($Value) | ForEach-Object { "$_" }) -join ","
    }

    if ($Value -is [bool]) {
        return "$Value".ToLowerInvariant()
    }

    return "$Value"
}

function Get-SupervisorManifestDiff {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,

        [Parameter(Mandatory)]
        [object]$Config
    )

    if (-not (Test-Path $ProjectPath)) {
        throw "プロジェクトディレクトリが見つかりません: $ProjectPath"
    }

    $projectName = Split-Path -Leaf $ProjectPath
    $codexDir = Join-Path $ProjectPath ".codex"
    $manifestPath = Join-Path $codexDir "supervisor.json"
    $desired = New-SupervisorManifest -Config $Config -ProjectName $projectName
    $current = $null
    $parseError = ""
    $exists = Test-Path $manifestPath

    if ($exists) {
        try {
            $current = Get-Content -Path $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $parseError = "$_"
        }
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    $policyKeys = @(
        "schemaVersion",
        "project",
        "managedBy",
        "mode",
        "agentLoop",
        "codexOnly",
        "sshEnabled",
        "humanDecisionRequired"
    )

    if ($exists -and -not $parseError) {
        foreach ($key in $policyKeys) {
            $currentValue = if ($current.PSObject.Properties[$key]) { $current.PSObject.Properties[$key].Value } else { $null }
            $desiredValue = if ($desired.PSObject.Properties[$key]) { $desired.PSObject.Properties[$key].Value } else { $null }
            $currentText = Convert-SupervisorDiffValue -Value $currentValue
            $desiredText = Convert-SupervisorDiffValue -Value $desiredValue
            if ($currentText -ne $desiredText) {
                $changeType = if ($null -eq $currentValue) { "Added" } elseif ($null -eq $desiredValue) { "Removed" } else { "Changed" }
                $changes.Add([pscustomobject]@{
                        property = $key
                        current  = $currentText
                        desired  = $desiredText
                        type     = $changeType
                    })
            }
        }
    }

    $action = if (-not $exists) {
        "Create"
    }
    elseif ($parseError) {
        "ReplaceInvalid"
    }
    elseif ($changes.Count -gt 0) {
        "Update"
    }
    else {
        "RefreshTimestamp"
    }

    return [pscustomobject]@{
        project              = $projectName
        path                 = $ProjectPath
        target               = $manifestPath
        exists               = $exists
        action               = $action
        changeCount          = $changes.Count
        changes              = @($changes)
        parseError           = $parseError
        timestampWillRefresh = $exists -and -not $parseError
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
    $diff = Get-SupervisorManifestDiff -ProjectPath $ProjectPath -Config $Config

    if (-not $PreviewOnly) {
        if (-not (Test-Path $codexDir)) {
            New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
    }

    return [pscustomobject]@{
        project              = $projectName
        path                 = $ProjectPath
        target               = $manifestPath
        applied              = -not $PreviewOnly
        action               = $diff.action
        changes              = @($diff.changes)
        changeCount          = $diff.changeCount
        parseError           = $diff.parseError
        timestampWillRefresh = $diff.timestampWillRefresh
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
    $codexOnly = if ($manifest -and $null -ne $manifest.PSObject.Properties["codexOnly"]?.Value) { [bool]$manifest.codexOnly } else { $false }
    $sshEnabled = if ($manifest -and $null -ne $manifest.PSObject.Properties["sshEnabled"]?.Value) { [bool]$manifest.sshEnabled } else { $false }

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
    "Get-RegisteredProjectCandidateInventory",
    "Get-RegisteredProjectCategoryMap",
    "Get-SupervisorManifestDiff",
    "Get-SupervisorReport",
    "Get-SupervisorStatusForProject",
    "New-SupervisorManifest",
    "Set-RegisteredProjectCategory",
    "Set-RegisteredProjectExclusion",
    "Set-SupervisorForProject",
    "Set-SupervisorForRegisteredProjects"
)
