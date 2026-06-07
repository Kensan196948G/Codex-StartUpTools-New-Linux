Set-StrictMode -Version Latest

$script:DefaultStatePath = "state.json"

$script:Zones = @{
    Green  = @{ Min = 0; Max = 60; Label = "Green"; Status = "Normal development" }
    Yellow = @{ Min = 60; Max = 75; Label = "Yellow"; Status = "Reduced build activity" }
    Orange = @{ Min = 75; Max = 90; Label = "Orange"; Status = "Monitor priority" }
    Red    = @{ Min = 90; Max = 100; Label = "Red"; Status = "Development stopped" }
}

$script:DefaultAllocation = @{
    monitor     = 10
    development = 35
    verify      = 25
    improvement = 10
    debug       = 20
}

function Get-StateFilePath {
    param([string]$RepoRoot)

    if (-not $RepoRoot) {
        $RepoRoot = (Get-Location).Path
    }

    return Join-Path $RepoRoot $script:DefaultStatePath
}

function New-TokenState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Returns an in-memory object only.")]
    param()

    return [pscustomobject]@{
        total_budget         = 100
        used                 = 0
        remaining            = 100
        allocation           = [pscustomobject]$script:DefaultAllocation
        dynamic_mode         = $true
        current_phase_budget = 0
        current_phase_used   = 0
    }
}

function Get-TokenState {
    param([string]$StatePath)

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    if (-not (Test-Path $StatePath)) {
        return New-TokenState
    }

    $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($state.PSObject.Properties.Name -contains "token") -or $null -eq $state.token) {
        return New-TokenState
    }

    return $state.token
}

function Get-TokenZone {
    param(
        [Parameter(Mandatory)]
        [double]$UsedPercent
    )

    if ($UsedPercent -lt 60) {
        return [pscustomobject]$script:Zones.Green
    }
    elseif ($UsedPercent -lt 75) {
        return [pscustomobject]$script:Zones.Yellow
    }
    elseif ($UsedPercent -lt 90) {
        return [pscustomobject]$script:Zones.Orange
    }

    return [pscustomobject]$script:Zones.Red
}

function Get-PhaseAllowance {
    param(
        [Parameter(Mandatory)]
        [object]$Zone
    )

    $result = [ordered]@{
        monitor     = $true
        development = $true
        verify      = $true
        improvement = $true
        debug       = $true
    }

    switch ($Zone.Label) {
        "Yellow" {
            $result.improvement = $false
        }
        "Orange" {
            $result.improvement = $false
            $result.development = $false
        }
        "Red" {
            $result.improvement = $false
            $result.development = $false
            $result.debug = $false
        }
    }

    return [pscustomobject]$result
}

function Update-TokenUsage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by unattended local automation.")]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("monitor", "development", "verify", "improvement", "debug")]
        [string]$Phase,

        [Parameter(Mandatory)]
        [double]$Amount,

        [string]$StatePath
    )

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    if (Test-Path $StatePath) {
        $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        $state = [pscustomobject]@{}
    }

    $hasToken = $false
    try {
        $hasToken = $null -ne $state.token
    }
    catch {
        $hasToken = $false
    }

    if (-not $hasToken) {
        $state | Add-Member -NotePropertyName "token" -NotePropertyValue (New-TokenState) -Force
    }

    $state.token.used = [math]::Min(100, $state.token.used + $Amount)
    $state.token.remaining = [math]::Max(0, $state.token.total_budget - $state.token.used)
    $state.token | Add-Member -NotePropertyName "current_phase" -NotePropertyValue $Phase -Force
    $state.token.current_phase_used = $state.token.current_phase_used + $Amount

    $json = $state | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StatePath, $json, [System.Text.UTF8Encoding]::new($false))

    return $state.token
}

function Get-TokenBudgetStatus {
    param([string]$StatePath)

    $token = Get-TokenState -StatePath $StatePath
    $usedPercent = if ($token.total_budget -gt 0) {
        ($token.used / $token.total_budget) * 100
    }
    else {
        0
    }

    $zone = Get-TokenZone -UsedPercent $usedPercent
    $allowance = Get-PhaseAllowance -Zone $zone

    return [pscustomobject]@{
        Used                  = $token.used
        Remaining             = $token.remaining
        TotalBudget           = $token.total_budget
        UsedPercent           = [math]::Round($usedPercent, 1)
        Zone                  = $zone
        Allowance             = $allowance
        Allocation            = $token.allocation
        DynamicMode           = $token.dynamic_mode
        ShouldStop            = ($zone.Label -eq "Red")
        ShouldSkipImprovement = ($zone.Label -ne "Green")
        ShouldVerifyOnly      = ($zone.Label -in @("Orange", "Red"))
    }
}

function Invoke-DynamicReallocation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("ci_failure", "stable", "time_pressure")]
        [string]$Condition,

        [string]$StatePath
    )

    if (-not $StatePath) {
        $StatePath = Get-StateFilePath
    }

    if (-not (Test-Path $StatePath)) {
        return $null
    }

    $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($state.PSObject.Properties.Name -contains "token") -or $null -eq $state.token -or -not $state.token.dynamic_mode) {
        return $null
    }

    $allocation = $state.token.allocation

    switch ($Condition) {
        "ci_failure" {
            $allocation.verify = [math]::Min(50, $allocation.verify + 20)
            $allocation.development = [math]::Max(15, $allocation.development - 20)
        }
        "stable" {
            $allocation.improvement = [math]::Min(20, $allocation.improvement + 10)
            $allocation.development = [math]::Max(25, $allocation.development - 10)
        }
        "time_pressure" {
            $allocation.improvement = 0
            $allocation.verify = [math]::Max(15, $allocation.verify - 10)
            $allocation.development = $allocation.development + 10
        }
    }

    $state.token.allocation = $allocation
    $json = $state | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StatePath, $json, [System.Text.UTF8Encoding]::new($false))

    return $allocation
}

function Show-TokenBudgetStatus {
    param([string]$StatePath)

    $status = Get-TokenBudgetStatus -StatePath $StatePath

    Write-Host "Token Budget Status:" -ForegroundColor Cyan
    Write-Host "  Used: $($status.UsedPercent)% ($($status.Used)/$($status.TotalBudget))"
    Write-Host "  Remaining: $($status.Remaining)"

    $zoneColor = switch ($status.Zone.Label) {
        "Green" { "Green" }
        "Yellow" { "Yellow" }
        "Orange" { "DarkYellow" }
        "Red" { "Red" }
    }

    Write-Host "  Zone: $($status.Zone.Label) - $($status.Zone.Status)" -ForegroundColor $zoneColor
    Write-Host "  Phases:" -ForegroundColor Cyan

    foreach ($phase in @("monitor", "development", "verify", "improvement", "debug")) {
        $allowed = $status.Allowance.$phase
        $icon = if ($allowed) { "[OK]" } else { "[--]" }
        $color = if ($allowed) { "Green" } else { "Yellow" }
        $budget = $status.Allocation.$phase
        Write-Host "    $icon $phase`: ${budget}%" -ForegroundColor $color
    }
}

Export-ModuleMember -Function @(
    "Get-StateFilePath",
    "Get-TokenState",
    "New-TokenState",
    "Get-TokenZone",
    "Get-PhaseAllowance",
    "Update-TokenUsage",
    "Get-TokenBudgetStatus",
    "Invoke-DynamicReallocation",
    "Show-TokenBudgetStatus"
)
