BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/WorktreeManager.psm1") -Force
}

Describe "Get-WorktreeBasePath" {
    It "RepoRoot を受けると .worktrees で終わる" {
        (Get-WorktreeBasePath -RepoRoot "/tmp/repo") | Should -Match "\.worktrees$"
    }

    It "RepoRoot と .worktrees を正しく結合する" {
        Get-WorktreeBasePath -RepoRoot "/home/kensan/Projects/myapp" | Should -Be (Join-Path "/home/kensan/Projects/myapp" ".worktrees")
    }

    It "スペースを含むパスでも扱える" {
        Get-WorktreeBasePath -RepoRoot "/tmp/my repos/project" | Should -Be (Join-Path "/tmp/my repos/project" ".worktrees")
    }
}

Describe "Get-WorktreeSummary" {
    It "worktree ごとに 1 件返す" {
        Mock -ModuleName WorktreeManager Get-Worktree {
            @(
                [pscustomobject]@{ Path = "/tmp/repo"; Commit = "abc1234def0"; Branch = "main"; IsBare = $false; IsMain = $true },
                [pscustomobject]@{ Path = "/tmp/repo/.worktrees/feat"; Commit = "xyz5678abc0"; Branch = "feat/my-feat"; IsBare = $false; IsMain = $false }
            )
        }

        @(Get-WorktreeSummary -RepoRoot "/tmp/repo").Count | Should -Be 2
    }

    It "main worktree に [MAIN] を付ける" {
        Mock -ModuleName WorktreeManager Get-Worktree {
            @([pscustomobject]@{ Path = "/tmp/repo"; Commit = "abc1234def0"; Branch = "main"; IsBare = $false; IsMain = $true })
        }

        (Get-WorktreeSummary -RepoRoot "/tmp/repo")[0].Label | Should -Be "[MAIN]"
    }

    It "Branch が null なら detached を返す" {
        Mock -ModuleName WorktreeManager Get-Worktree {
            @([pscustomobject]@{ Path = "/tmp/repo/.worktrees/detach"; Commit = "abc1234def0"; Branch = $null; IsBare = $false; IsMain = $false })
        }

        (Get-WorktreeSummary -RepoRoot "/tmp/repo")[0].Branch | Should -Be "(detached)"
    }

    It "Commit を 7 桁に切り詰める" {
        Mock -ModuleName WorktreeManager Get-Worktree {
            @([pscustomobject]@{ Path = "/tmp/repo"; Commit = "abc1234def567"; Branch = "main"; IsBare = $false; IsMain = $true })
        }

        (Get-WorktreeSummary -RepoRoot "/tmp/repo")[0].Commit | Should -Be "abc1234"
    }
}
