Set-StrictMode -Version Latest

function New-GitHubPrFlowResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Factory function that only returns an in-memory result object.")]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Ok,

        [string]$Detail = "",
        [string]$Category = "github"
    )

    return [pscustomobject]@{
        Name     = $Name
        Ok       = $Ok
        Detail   = $Detail
        Category = $Category
    }
}

function Convert-GitHubRemoteToRepositoryName {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [string]$RemoteUrl = ""
    )

    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        return ""
    }

    if ($RemoteUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return "{0}/{1}" -f $Matches.owner, $Matches.repo
    }

    return ""
}

function Test-GitHubProtectedBranchName {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [string[]]$ProtectedBranches = @("main", "master", "develop")
    )

    return $Branch -in $ProtectedBranches
}

function Get-GitHubCheckRollupSummary {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [object[]]$StatusCheckRollup = @()
    )

    $success = 0
    $pending = 0
    $failure = 0

    foreach ($check in @($StatusCheckRollup)) {
        $conclusion = if ($check.PSObject.Properties["conclusion"]) { "$($check.conclusion)" } else { "" }
        $status = if ($check.PSObject.Properties["status"]) { "$($check.status)" } else { "" }
        $state = if ($check.PSObject.Properties["state"]) { "$($check.state)" } else { "" }

        if ($conclusion -in @("SUCCESS", "NEUTRAL", "SKIPPED") -or $state -eq "SUCCESS") {
            $success++
        }
        elseif ($conclusion -in @("FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED") -or $state -in @("ERROR", "FAILURE")) {
            $failure++
        }
        elseif ($status -and $status -ne "COMPLETED") {
            $pending++
        }
        elseif ($state -eq "PENDING") {
            $pending++
        }
        else {
            $pending++
        }
    }

    return [pscustomobject]@{
        success = $success
        pending = $pending
        failure = $failure
        total   = $success + $pending + $failure
    }
}

function Get-GitHubCurrentBranch {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    return (git -C $ProjectRoot branch --show-current 2>$null)
}

function Get-GitHubRemoteRepositoryName {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    $remoteUrl = git -C $ProjectRoot remote get-url origin 2>$null
    return Convert-GitHubRemoteToRepositoryName -RemoteUrl $remoteUrl
}

function Get-GitHubPullRequest {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    Push-Location $ProjectRoot
    try {
        $raw = gh pr view --json number,title,url,isDraft,state,mergeable,statusCheckRollup 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        return ($raw | ConvertFrom-Json)
    }
    finally {
        Pop-Location
    }
}

function New-GitHubDraftPullRequest {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Draft PR creation is gated by explicit -CreateDraft on the caller command.")]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$Base = "main",
        [string]$Title = "Prepare v0.2.0",
        [string]$Body = ""
    )

    $bodyText = if ([string]::IsNullOrWhiteSpace($Body)) {
        @"
## Summary

- Prepare v0.2.0 development changes.

## Human Decision Gates

- No release tag should be created by automation.
- No merge should be performed by automation.
- Release and public visibility remain human decisions.
"@
    }
    else {
        $Body
    }

    Push-Location $ProjectRoot
    try {
        $bodyFile = New-TemporaryFile
        Set-Content -Path $bodyFile -Value $bodyText -Encoding UTF8
        $output = gh pr create --draft --base $Base --title $Title --body-file $bodyFile 2>&1
        $exitCode = $LASTEXITCODE
        Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
        if ($exitCode -ne 0) {
            throw ($output -join " ")
        }

        return ($output | Select-Object -Last 1)
    }
    finally {
        Pop-Location
    }
}

function Invoke-GitHubPrFlow {
    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$Base = "main",
        [string]$Title = "Prepare v0.2.0",
        [switch]$CreateDraft
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $ghAvailable = [bool](Get-Command gh -ErrorAction SilentlyContinue)
    $checks.Add((New-GitHubPrFlowResult -Name "gh CLI" -Ok $ghAvailable -Detail $(if ($ghAvailable) { "available" } else { "gh not found" })))

    $branch = Get-GitHubCurrentBranch -ProjectRoot $ProjectRoot
    $branchOk = -not [string]::IsNullOrWhiteSpace($branch) -and -not (Test-GitHubProtectedBranchName -Branch $branch)
    $checks.Add((New-GitHubPrFlowResult -Name "Current branch" -Ok $branchOk -Detail $(if ($branch) { $branch } else { "branch not detected" }) -Category "git"))

    $repoName = Get-GitHubRemoteRepositoryName -ProjectRoot $ProjectRoot
    $checks.Add((New-GitHubPrFlowResult -Name "GitHub remote" -Ok (-not [string]::IsNullOrWhiteSpace($repoName)) -Detail $(if ($repoName) { $repoName } else { "origin is not a GitHub remote" }) -Category "git"))

    $authOk = $false
    if ($ghAvailable) {
        gh auth status 2>$null | Out-Null
        $authOk = $LASTEXITCODE -eq 0
    }
    $checks.Add((New-GitHubPrFlowResult -Name "gh auth" -Ok $authOk -Detail $(if ($authOk) { "authenticated" } else { "not authenticated" })))

    $pr = $null
    if ($ghAvailable -and $authOk -and $branchOk) {
        $pr = Get-GitHubPullRequest -ProjectRoot $ProjectRoot
        if ($null -eq $pr -and $CreateDraft) {
            New-GitHubDraftPullRequest -ProjectRoot $ProjectRoot -Base $Base -Title $Title | Out-Null
            $pr = Get-GitHubPullRequest -ProjectRoot $ProjectRoot
        }
    }

    if ($null -eq $pr) {
        $detail = if ($CreateDraft) { "draft PR not created" } else { "no PR found; run with -CreateDraft to create one" }
        $checks.Add((New-GitHubPrFlowResult -Name "Pull request" -Ok (-not [bool]$CreateDraft) -Detail $detail))
        $checks.Add((New-GitHubPrFlowResult -Name "PR checks" -Ok $true -Detail "not checked"))
    }
    else {
        $prDetail = "#{0} {1} draft={2} {3}" -f $pr.number, $pr.state, $pr.isDraft, $pr.url
        $checks.Add((New-GitHubPrFlowResult -Name "Pull request" -Ok $true -Detail $prDetail))

        $summary = Get-GitHubCheckRollupSummary -StatusCheckRollup @($pr.statusCheckRollup)
        $checkOk = $summary.failure -eq 0 -and $summary.pending -eq 0
        $checkDetail = "success={0}; pending={1}; failure={2}" -f $summary.success, $summary.pending, $summary.failure
        $checks.Add((New-GitHubPrFlowResult -Name "PR checks" -Ok $checkOk -Detail $checkDetail -Category "ci"))
    }

    $failed = @($checks | Where-Object { -not $_.Ok })
    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("o")
        repository  = $repoName
        branch      = $branch
        base        = $Base
        passed      = $failed.Count -eq 0
        total       = $checks.Count
        failed      = $failed.Count
        checks      = @($checks)
    }
}

function Write-GitHubPrFlowReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Report
    )

    Write-Host ""
    Write-Host "GitHub PR Flow Check" -ForegroundColor Cyan
    Write-Host ("  Repository : {0}" -f $Report.repository)
    Write-Host ("  Branch     : {0}" -f $Report.branch)
    Write-Host ("  Base       : {0}" -f $Report.base)
    Write-Host ("  Result     : {0}" -f $(if ($Report.passed) { "PASS" } else { "CHECK" })) -ForegroundColor $(if ($Report.passed) { "Green" } else { "Yellow" })
    Write-Host ""

    foreach ($check in @($Report.checks)) {
        $mark = if ($check.Ok) { "[OK]" } else { "[NG]" }
        $color = if ($check.Ok) { "Green" } else { "Yellow" }
        Write-Host ("  {0} {1} - {2}" -f $mark, $check.Name, $check.Detail) -ForegroundColor $color
    }

    Write-Host ""
}

Export-ModuleMember -Function @(
    "Convert-GitHubRemoteToRepositoryName",
    "Get-GitHubCheckRollupSummary",
    "Get-GitHubCurrentBranch",
    "Get-GitHubPullRequest",
    "Get-GitHubRemoteRepositoryName",
    "Invoke-GitHubPrFlow",
    "New-GitHubDraftPullRequest",
    "New-GitHubPrFlowResult",
    "Test-GitHubProtectedBranchName",
    "Write-GitHubPrFlowReport"
)
