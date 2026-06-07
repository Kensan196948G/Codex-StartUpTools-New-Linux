Set-StrictMode -Version Latest

$script:DefaultWorktreeBase = ".worktrees"

function Get-WorktreeBasePath {
    param(
        [string]$RepoRoot
    )

    if (-not $RepoRoot) {
        $RepoRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $RepoRoot) {
            throw "Not inside a Git repository."
        }
    }

    return Join-Path $RepoRoot $script:DefaultWorktreeBase
}

function Get-Worktree {
    param(
        [string]$RepoRoot
    )

    if (-not $RepoRoot) {
        $RepoRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $RepoRoot) {
            throw "Not inside a Git repository."
        }
    }

    $raw = git -C $RepoRoot worktree list --porcelain 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list worktrees: $raw"
    }

    $worktrees = @()
    $current = @{}
    $normalizedRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) {
                $wtPath = $current["worktree"]
                $normalizedWt = [System.IO.Path]::GetFullPath($wtPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                $worktrees += [pscustomobject]@{
                    Path   = $wtPath
                    Commit = $current["HEAD"]
                    Branch = if ($current.ContainsKey("branch")) { $current["branch"] -replace "^refs/heads/", "" } else { $null }
                    IsBare = $current.ContainsKey("bare")
                    IsMain = ($normalizedWt -eq $normalizedRoot)
                }
                $current = @{}
            }
            continue
        }

        if ($line -match "^worktree (.+)$") {
            $current["worktree"] = $Matches[1]
        }
        elseif ($line -match "^HEAD (.+)$") {
            $current["HEAD"] = $Matches[1]
        }
        elseif ($line -match "^branch (.+)$") {
            $current["branch"] = $Matches[1]
        }
        elseif ($line -eq "bare") {
            $current["bare"] = $true
        }
    }

    if ($current.Count -gt 0) {
        $wtPath = $current["worktree"]
        $normalizedWt = [System.IO.Path]::GetFullPath($wtPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $worktrees += [pscustomobject]@{
            Path   = $wtPath
            Commit = $current["HEAD"]
            Branch = if ($current.ContainsKey("branch")) { $current["branch"] -replace "^refs/heads/", "" } else { $null }
            IsBare = $current.ContainsKey("bare")
            IsMain = ($normalizedWt -eq $normalizedRoot)
        }
    }

    return $worktrees
}

function New-Worktree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by unattended local automation.")]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [string]$BaseBranch = "main",
        [string]$RepoRoot,
        [string]$WorktreeDir
    )

    if (-not $RepoRoot) {
        $RepoRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $RepoRoot) {
            throw "Not inside a Git repository."
        }
    }

    $existingBranch = git -C $RepoRoot branch --list $BranchName 2>$null
    if ($existingBranch) {
        throw "Branch '$BranchName' already exists. Use Switch-Worktree or choose a different name."
    }

    if (-not $WorktreeDir) {
        $basePath = Get-WorktreeBasePath -RepoRoot $RepoRoot
        $safeName = $BranchName -replace "[/\\:]", "-"
        $WorktreeDir = Join-Path $basePath $safeName
    }

    if (Test-Path $WorktreeDir) {
        throw "Worktree directory already exists: $WorktreeDir"
    }

    $parentDir = Split-Path -Parent $WorktreeDir
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $result = git -C $RepoRoot worktree add -b $BranchName $WorktreeDir $BaseBranch 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create worktree: $result"
    }

    return [pscustomobject]@{
        Path       = $WorktreeDir
        Branch     = $BranchName
        BaseBranch = $BaseBranch
        Created    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

function Switch-Worktree {
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [string]$RepoRoot
    )

    $worktrees = Get-Worktree -RepoRoot $RepoRoot
    $target = $worktrees | Where-Object { $_.Branch -eq $BranchName }

    if (-not $target) {
        throw "No worktree found for branch '$BranchName'. Available: $(($worktrees | Where-Object { $_.Branch } | ForEach-Object { $_.Branch }) -join ', ')"
    }

    return $target
}

function Remove-Worktree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Used by unattended local automation.")]
    param(
        [Parameter(Mandatory)]
        [string]$BranchName,

        [switch]$DeleteBranch,
        [switch]$Force,
        [string]$RepoRoot
    )

    if (-not $RepoRoot) {
        $RepoRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $RepoRoot) {
            throw "Not inside a Git repository."
        }
    }

    $worktree = Switch-Worktree -BranchName $BranchName -RepoRoot $RepoRoot
    if ($worktree.IsMain) {
        throw "Cannot remove the main worktree."
    }

    $removeArgs = @("-C", $RepoRoot, "worktree", "remove")
    if ($Force) {
        $removeArgs += "--force"
    }
    $removeArgs += $worktree.Path

    $result = & git @removeArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove worktree: $result"
    }

    if ($DeleteBranch) {
        $deleteFlag = if ($Force) { "-D" } else { "-d" }
        $branchResult = git -C $RepoRoot branch $deleteFlag $BranchName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Worktree removed but failed to delete branch: $branchResult"
        }
    }

    git -C $RepoRoot worktree prune 2>$null

    return [pscustomobject]@{
        RemovedPath   = $worktree.Path
        Branch        = $BranchName
        BranchDeleted = [bool]$DeleteBranch
    }
}

function Get-WorktreeSummary {
    param(
        [string]$RepoRoot
    )

    $worktrees = Get-Worktree -RepoRoot $RepoRoot
    $summary = @()

    foreach ($wt in $worktrees) {
        $label = if ($wt.IsMain) { "[MAIN]" } else { "" }
        $branch = if ($wt.Branch) { $wt.Branch } else { "(detached)" }
        $commit = if ($wt.Commit) { $wt.Commit.Substring(0, 7) } else { "unknown" }

        $summary += [pscustomobject]@{
            Branch = $branch
            Commit = $commit
            Path   = $wt.Path
            Label  = $label
        }
    }

    return $summary
}

function Invoke-WorktreeCleanup {
    param(
        [string]$BaseBranch = "main",
        [string]$RepoRoot,
        [switch]$DryRun
    )

    if (-not $RepoRoot) {
        $RepoRoot = (git rev-parse --show-toplevel 2>$null)
        if (-not $RepoRoot) {
            throw "Not inside a Git repository."
        }
    }

    $mergedRaw = git -C $RepoRoot branch --merged $BaseBranch 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list merged branches: $mergedRaw"
    }

    $mergedBranches = @($mergedRaw | ForEach-Object { $_.Trim().TrimStart('* +') } | Where-Object { $_ -and $_ -ne $BaseBranch -and $_ -ne "master" })
    $worktrees = Get-Worktree -RepoRoot $RepoRoot
    $candidates = @()

    foreach ($wt in $worktrees) {
        if ($wt.IsMain -or -not $wt.Branch) {
            continue
        }
        if ($wt.Branch -in $mergedBranches) {
            $candidates += $wt
        }
    }

    if ($DryRun) {
        return [pscustomobject]@{
            WouldRemove = @($candidates | ForEach-Object { [pscustomobject]@{ Branch = $_.Branch; Path = $_.Path } })
            Count       = $candidates.Count
        }
    }

    $removed = @()
    foreach ($wt in $candidates) {
        try {
            $null = Remove-Worktree -BranchName $wt.Branch -DeleteBranch -RepoRoot $RepoRoot
            $removed += [pscustomobject]@{
                Branch = $wt.Branch
                Path   = $wt.Path
                Status = "removed"
            }
        }
        catch {
            $removed += [pscustomobject]@{
                Branch = $wt.Branch
                Path   = $wt.Path
                Status = "failed: $($_.Exception.Message)"
            }
        }
    }

    return [pscustomobject]@{
        Removed = $removed
        Count   = @($removed | Where-Object { $_.Status -eq "removed" }).Count
        Total   = $removed.Count
    }
}

Export-ModuleMember -Function @(
    "Get-Worktree",
    "New-Worktree",
    "Switch-Worktree",
    "Remove-Worktree",
    "Get-WorktreeSummary",
    "Get-WorktreeBasePath",
    "Invoke-WorktreeCleanup"
)
