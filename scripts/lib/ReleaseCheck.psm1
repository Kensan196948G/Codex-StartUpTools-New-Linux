Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "Config.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "ArchitectureCheck.psm1") -Force

function New-ReleaseCheckResult {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Ok,

        [string]$Detail = "",
        [string]$Category = "release"
    )

    return [pscustomobject]@{
        Name     = $Name
        Ok       = $Ok
        Detail   = $Detail
        Category = $Category
    }
}

function Test-ReleaseGitState {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [switch]$AllowDirty
    )

    $gitRoot = git -C $ProjectRoot rev-parse --show-toplevel 2>$null
    if ([string]::IsNullOrWhiteSpace($gitRoot)) {
        return New-ReleaseCheckResult -Name "Git repository" -Ok $false -Detail "git repository not detected" -Category "git"
    }

    $status = @(git -C $ProjectRoot status --porcelain 2>$null)
    if ($status.Count -eq 0) {
        return New-ReleaseCheckResult -Name "Git worktree" -Ok $true -Detail "clean" -Category "git"
    }

    $detail = "dirty: {0} item(s)" -f $status.Count
    return New-ReleaseCheckResult -Name "Git worktree" -Ok ([bool]$AllowDirty) -Detail $detail -Category "git"
}

function Test-ReleaseIgnoredPath {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string[]]$RequiredPatterns = @("config/config.json", "state.json", "logs/")
    )

    $gitignorePath = Join-Path $ProjectRoot ".gitignore"
    if (-not (Test-Path $gitignorePath)) {
        return New-ReleaseCheckResult -Name ".gitignore" -Ok $false -Detail ".gitignore not found" -Category "git"
    }

    $lines = @(Get-Content -Path $gitignorePath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") })
    $missing = @($RequiredPatterns | Where-Object { $_ -notin $lines })
    $ok = $missing.Count -eq 0
    $detail = if ($ok) { "runtime paths are ignored" } else { "missing: {0}" -f ($missing -join ", ") }
    return New-ReleaseCheckResult -Name "Runtime gitignore" -Ok $ok -Detail $detail -Category "git"
}

function Test-ReleaseReadmeRequirement {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string[]]$RequiredText = @("Supervisorレポート", "更新差分表示", "プロジェクト候補管理", "リリース")
    )

    $readmePath = Join-Path $ProjectRoot "README.md"
    if (-not (Test-Path $readmePath)) {
        return New-ReleaseCheckResult -Name "README" -Ok $false -Detail "README.md not found" -Category "docs"
    }

    $content = Get-Content -Path $readmePath -Raw -Encoding UTF8
    $missing = @($RequiredText | Where-Object { $content -notmatch [regex]::Escape($_) })
    $ok = $missing.Count -eq 0
    $detail = if ($ok) { "required release docs are present" } else { "missing text: {0}" -f ($missing -join ", ") }
    return New-ReleaseCheckResult -Name "README release docs" -Ok $ok -Detail $detail -Category "docs"
}

function Test-ReleaseConfigTemplate {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $templatePath = Join-Path $ProjectRoot "config/config.json.template"
    if (-not (Test-Path $templatePath)) {
        return New-ReleaseCheckResult -Name "Config template" -Ok $false -Detail "config/config.json.template not found" -Category "config"
    }

    try {
        $config = Get-Content -Path $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $errors = @(Test-StartupConfigSchema -Config $config)
        if ($errors.Count -gt 0) {
            return New-ReleaseCheckResult -Name "Config template" -Ok $false -Detail ($errors -join "; ") -Category "config"
        }

        $root = "$($config.registeredProjects.roots[0])"
        $isLinuxDefault = $root -eq "/home/kensan/Projects"
        return New-ReleaseCheckResult -Name "Config template" -Ok $isLinuxDefault -Detail ("registeredProjects.roots[0]={0}" -f $root) -Category "config"
    }
    catch {
        return New-ReleaseCheckResult -Name "Config template" -Ok $false -Detail "$_" -Category "config"
    }
}

function Invoke-ReleasePesterCheck {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $testPath = Join-Path $ProjectRoot "tests/unit"
    $command = @"
Import-Module Pester -MinimumVersion 5.0 -Force
`$result = Invoke-Pester -Path '$testPath' -Output Normal -PassThru
if (`$result.FailedCount -gt 0) { exit 1 }
exit 0
"@

    $output = & pwsh -NoProfile -Command $command 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return New-ReleaseCheckResult -Name "Pester unit tests" -Ok $true -Detail "passed" -Category "test"
    }

    return New-ReleaseCheckResult -Name "Pester unit tests" -Ok $false -Detail (($output | Select-Object -Last 8) -join " ") -Category "test"
}

function Invoke-ReleaseArchitectureCheck {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    try {
        $result = Invoke-ArchitectureCheck -Path (Join-Path $ProjectRoot "scripts")
        $detail = "critical={0}; warning={1}; checked={2}" -f $result.CriticalCount, $result.WarningCount, $result.CheckedFiles
        return New-ReleaseCheckResult -Name "ArchitectureCheck" -Ok ([bool]$result.Passed) -Detail $detail -Category "architecture"
    }
    catch {
        return New-ReleaseCheckResult -Name "ArchitectureCheck" -Ok $false -Detail "$_" -Category "architecture"
    }
}

function Invoke-ReleaseDryRunCheck {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$Project
    )

    $scriptPath = Join-Path $ProjectRoot "scripts/main/Start-Codex.ps1"
    if (-not (Test-Path $scriptPath)) {
        return New-ReleaseCheckResult -Name "Codex dry-run" -Ok $false -Detail "Start-Codex.ps1 not found" -Category "runtime"
    }

    $output = & pwsh -NoProfile -File $scriptPath -Project $Project -DryRun -NonInteractive 2>&1
    $exitCode = $LASTEXITCODE
    $detail = if ($exitCode -eq 0) { "READY" } else { ($output -join " ") }
    return New-ReleaseCheckResult -Name "Codex dry-run" -Ok ($exitCode -eq 0) -Detail $detail -Category "runtime"
}

function Invoke-ReleaseCheck {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$Project = "Codex-StartUpTools-New-Linux",
        [switch]$SkipPester,
        [switch]$SkipDryRun,
        [switch]$AllowDirty
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add((Test-ReleaseGitState -ProjectRoot $ProjectRoot -AllowDirty:$AllowDirty))
    $checks.Add((Test-ReleaseIgnoredPath -ProjectRoot $ProjectRoot))
    $checks.Add((Test-ReleaseReadmeRequirement -ProjectRoot $ProjectRoot))
    $checks.Add((Test-ReleaseConfigTemplate -ProjectRoot $ProjectRoot))

    if (-not $SkipPester) {
        $checks.Add((Invoke-ReleasePesterCheck -ProjectRoot $ProjectRoot))
    }
    if (-not $SkipDryRun) {
        $checks.Add((Invoke-ReleaseDryRunCheck -ProjectRoot $ProjectRoot -Project $Project))
    }

    $checks.Add((Invoke-ReleaseArchitectureCheck -ProjectRoot $ProjectRoot))

    $failed = @($checks | Where-Object { -not $_.Ok })
    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("o")
        project     = $Project
        passed      = $failed.Count -eq 0
        total       = $checks.Count
        failed      = $failed.Count
        checks      = @($checks)
    }
}

function Write-ReleaseCheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Report
    )

    Write-Host ""
    Write-Host "Release Readiness Check" -ForegroundColor Cyan
    Write-Host ("  Project : {0}" -f $Report.project)
    Write-Host ("  Result  : {0}" -f $(if ($Report.passed) { "PASS" } else { "FAIL" })) -ForegroundColor $(if ($Report.passed) { "Green" } else { "Red" })
    Write-Host ("  Checks  : {0} total / {1} failed" -f $Report.total, $Report.failed)
    Write-Host ""

    foreach ($check in @($Report.checks)) {
        $mark = if ($check.Ok) { "[OK]" } else { "[NG]" }
        $color = if ($check.Ok) { "Green" } else { "Red" }
        Write-Host ("  {0} {1} - {2}" -f $mark, $check.Name, $check.Detail) -ForegroundColor $color
    }

    Write-Host ""
}

Export-ModuleMember -Function @(
    "Invoke-ReleaseArchitectureCheck",
    "Invoke-ReleaseCheck",
    "Invoke-ReleaseDryRunCheck",
    "Invoke-ReleasePesterCheck",
    "New-ReleaseCheckResult",
    "Test-ReleaseConfigTemplate",
    "Test-ReleaseGitState",
    "Test-ReleaseIgnoredPath",
    "Test-ReleaseReadmeRequirement",
    "Write-ReleaseCheckReport"
)
