BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/GitHubPrFlow.psm1") -Force
}

Describe "Convert-GitHubRemoteToRepositoryName" {
    It "HTTPS remote を owner/repo に変換する" {
        Convert-GitHubRemoteToRepositoryName -RemoteUrl "https://github.com/Kensan196948G/Codex-StartUpTools-New-Linux.git" |
            Should -Be "Kensan196948G/Codex-StartUpTools-New-Linux"
    }

    It "SSH remote を owner/repo に変換する" {
        Convert-GitHubRemoteToRepositoryName -RemoteUrl "git@github.com:Kensan196948G/Codex-StartUpTools-New-Linux.git" |
            Should -Be "Kensan196948G/Codex-StartUpTools-New-Linux"
    }

    It "GitHub以外は空文字を返す" {
        Convert-GitHubRemoteToRepositoryName -RemoteUrl "https://example.com/demo/repo.git" | Should -Be ""
    }
}

Describe "Test-GitHubProtectedBranchName" {
    It "main は protected として扱う" {
        Test-GitHubProtectedBranchName -Branch "main" | Should -BeTrue
    }

    It "作業ブランチは protected ではない" {
        Test-GitHubProtectedBranchName -Branch "codex/v0.2.0-supervisor-reporting" | Should -BeFalse
    }
}

Describe "Get-GitHubCheckRollupSummary" {
    It "success / pending / failure を集計する" {
        $checks = @(
            [pscustomobject]@{ conclusion = "SUCCESS"; status = "COMPLETED" },
            [pscustomobject]@{ conclusion = ""; status = "IN_PROGRESS" },
            [pscustomobject]@{ conclusion = "FAILURE"; status = "COMPLETED" },
            [pscustomobject]@{ state = "SUCCESS" }
        )

        $summary = Get-GitHubCheckRollupSummary -StatusCheckRollup $checks

        $summary.success | Should -Be 2
        $summary.pending | Should -Be 1
        $summary.failure | Should -Be 1
        $summary.total | Should -Be 4
    }
}

Describe "New-GitHubPrFlowResult" {
    It "結果オブジェクトを返す" {
        $result = New-GitHubPrFlowResult -Name "PR" -Ok $true -Detail "ok"

        $result.Name | Should -Be "PR"
        $result.Ok | Should -BeTrue
        $result.Detail | Should -Be "ok"
        $result.Category | Should -Be "github"
    }
}
