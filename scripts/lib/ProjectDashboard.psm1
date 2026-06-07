Set-StrictMode -Version Latest

function Get-ProjectDashboardInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$StatePath = "",
        [string]$ConfigPath = ""
    )

    $gitInfo = Get-DashboardGitInfo -ProjectRoot $ProjectRoot
    $testInfo = Get-DashboardTestInfo -ProjectRoot $ProjectRoot
    $tokenInfo = Get-DashboardTokenInfo -StatePath $StatePath -ProjectRoot $ProjectRoot
    $phaseInfo = Get-DashboardPhaseInfo -StatePath $StatePath -ProjectRoot $ProjectRoot

    return [pscustomobject]@{
        ProjectRoot = $ProjectRoot
        ProjectName = Split-Path $ProjectRoot -Leaf
        Git         = $gitInfo
        Tests       = $testInfo
        Token       = $tokenInfo
        Phase       = $phaseInfo
        Timestamp   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

function Get-DashboardGitInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $branch = ""
    $lastCommit = ""
    $lastCommitDate = ""
    $isClean = $true
    $aheadBehind = ""

    try {
        $branch = & git -C $ProjectRoot rev-parse --abbrev-ref HEAD 2>$null
        $lastLog = & git -C $ProjectRoot log -1 --format="%s|%ar" 2>$null
        if ($lastLog) {
            $parts = $lastLog -split "\|"
            $lastCommit = if ($parts.Count -ge 1) { $parts[0] } else { "" }
            $lastCommitDate = if ($parts.Count -ge 2) { $parts[1] } else { "" }
        }
        $statusOutput = & git -C $ProjectRoot status --porcelain 2>$null
        $isClean = [string]::IsNullOrWhiteSpace($statusOutput)
        $aheadBehind = & git -C $ProjectRoot rev-list --left-right --count "HEAD...@{u}" 2>$null
    }
    catch {
        # git not available or not a repo — return defaults
    }

    return [pscustomobject]@{
        Branch        = if ($branch) { $branch } else { "(unknown)" }
        LastCommit    = if ($lastCommit) { $lastCommit } else { "(no commits)" }
        LastCommitAge = if ($lastCommitDate) { $lastCommitDate } else { "" }
        IsClean       = $isClean
        AheadBehind   = if ($aheadBehind) { $aheadBehind } else { "" }
    }
}

function Get-DashboardTestInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $testPath = Join-Path $ProjectRoot "tests/unit"
    $testFiles = @()
    $totalTests = 0
    $resultsPath = Join-Path $ProjectRoot "testResults.xml"

    if (Test-Path $testPath) {
        $testFiles = @(Get-ChildItem -Path $testPath -Filter "*.Tests.ps1" -ErrorAction SilentlyContinue)
    }

    if (Test-Path $resultsPath) {
        try {
            [xml]$xml = Get-Content $resultsPath -Raw -Encoding UTF8
            $total = $xml.'test-results'.total
            if ($total -match '^\d+$') {
                $totalTests = [int]$total
            }
        }
        catch { }
    }

    return [pscustomobject]@{
        TestFileCount = $testFiles.Count
        LastRunTotal  = $totalTests
        ResultsPath   = $resultsPath
        HasResults    = (Test-Path $resultsPath)
    }
}

function Get-DashboardTokenInfo {
    [CmdletBinding()]
    param(
        [string]$StatePath,
        [string]$ProjectRoot
    )

    if (-not $StatePath) {
        $StatePath = Join-Path $ProjectRoot "state.json"
    }

    if (-not (Test-Path $StatePath)) {
        return [pscustomobject]@{
            Used      = 0
            Remaining = 100
            Zone      = "Green"
            Available = $false
        }
    }

    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $used = if ($state.PSObject.Properties["token"] -and $state.token.PSObject.Properties["used"]) {
            [int]$state.token.used
        } else { 0 }
        $remaining = 100 - $used
        $zone = if ($used -ge 95) { "Red" }
                elseif ($used -ge 85) { "Orange" }
                elseif ($used -ge 70) { "Yellow" }
                else { "Green" }
        return [pscustomobject]@{
            Used      = $used
            Remaining = $remaining
            Zone      = $zone
            Available = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Used      = 0
            Remaining = 100
            Zone      = "Green"
            Available = $false
        }
    }
}

function Get-DashboardPhaseInfo {
    [CmdletBinding()]
    param(
        [string]$StatePath,
        [string]$ProjectRoot
    )

    if (-not $StatePath) {
        $StatePath = Join-Path $ProjectRoot "state.json"
    }

    if (-not (Test-Path $StatePath)) {
        return [pscustomobject]@{
            Current  = "Unknown"
            Stable   = $false
            Goal     = ""
            Available = $false
        }
    }

    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $phase = if ($state.PSObject.Properties["execution"] -and
                     $state.execution.PSObject.Properties["phase"]) {
            $state.execution.phase
        } else { "Unknown" }
        $stable = if ($state.PSObject.Properties["status"] -and
                      $state.status.PSObject.Properties["stable"]) {
            [bool]$state.status.stable
        } else { $false }
        $goal = if ($state.PSObject.Properties["goal"] -and
                    $state.goal.PSObject.Properties["title"]) {
            $state.goal.title
        } else { "" }

        return [pscustomobject]@{
            Current   = $phase
            Stable    = $stable
            Goal      = $goal
            Available = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Current  = "Unknown"
            Stable   = $false
            Goal     = ""
            Available = $false
        }
    }
}

function Show-ProjectDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$StatePath = "",
        [switch]$Compact
    )

    $info = Get-ProjectDashboardInfo -ProjectRoot $ProjectRoot -StatePath $StatePath

    $stableLabel = if ($info.Phase.Stable) { "[STABLE]" } else { "[unstable]" }
    $stableColor = if ($info.Phase.Stable) { "Green" } else { "Yellow" }
    $cleanLabel = if ($info.Git.IsClean) { "clean" } else { "dirty" }
    $cleanColor = if ($info.Git.IsClean) { "Green" } else { "Yellow" }
    $tokenColor = switch ($info.Token.Zone) {
        "Red" { "Red" }
        "Orange" { "Yellow" }
        "Yellow" { "Yellow" }
        default { "Green" }
    }

    Write-Host ""
    Write-Host "=== Codex StartUp Dashboard ===" -ForegroundColor Cyan
    Write-Host ("  Project  : {0}" -f $info.ProjectName)
    Write-Host ("  Root     : {0}" -f $info.ProjectRoot)
    Write-Host ("  Time     : {0}" -f $info.Timestamp)
    Write-Host ""

    Write-Host "  Git" -ForegroundColor Magenta
    Write-Host ("    Branch : {0}  ({1})" -f $info.Git.Branch, $cleanLabel) -ForegroundColor $cleanColor
    Write-Host ("    Last   : {0}" -f $info.Git.LastCommit)
    if ($info.Git.LastCommitAge) {
        Write-Host ("    Age    : {0}" -f $info.Git.LastCommitAge)
    }

    Write-Host ""
    Write-Host "  Tests" -ForegroundColor Magenta
    Write-Host ("    Files  : {0} test files" -f $info.Tests.TestFileCount)
    if ($info.Tests.HasResults) {
        Write-Host ("    Last   : {0} tests in last run" -f $info.Tests.LastRunTotal)
    }
    else {
        Write-Host "    Last   : (no results file)"
    }

    if (-not $Compact) {
        Write-Host ""
        Write-Host "  State" -ForegroundColor Magenta
        if ($info.Phase.Available) {
            Write-Host ("    Phase  : {0}" -f $info.Phase.Current)
            Write-Host ("    Stable : {0}" -f $stableLabel) -ForegroundColor $stableColor
            if ($info.Phase.Goal) {
                Write-Host ("    Goal   : {0}" -f $info.Phase.Goal)
            }
        }
        else {
            Write-Host "    State  : (state.json not found)"
        }

        Write-Host ""
        Write-Host "  Token" -ForegroundColor Magenta
        Write-Host ("    Used   : {0}%  Zone: {1}" -f $info.Token.Used, $info.Token.Zone) -ForegroundColor $tokenColor
        Write-Host ("    Left   : {0}%" -f $info.Token.Remaining)
    }

    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    return $info
}

Export-ModuleMember -Function @(
    "Get-ProjectDashboardInfo",
    "Get-DashboardGitInfo",
    "Get-DashboardTestInfo",
    "Get-DashboardTokenInfo",
    "Get-DashboardPhaseInfo",
    "Show-ProjectDashboard"
)
