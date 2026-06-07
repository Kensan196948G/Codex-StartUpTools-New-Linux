BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/ProjectDashboard.psm1") -Force
}

Describe "Get-DashboardGitInfo" {
    It "有効な Git リポジトリでブランチ名を返す" {
        $result = Get-DashboardGitInfo -ProjectRoot $script:RepoRoot
        $result.Branch | Should -Not -BeNullOrEmpty
    }

    It "有効な Git リポジトリで IsClean プロパティを持つ" {
        $result = Get-DashboardGitInfo -ProjectRoot $script:RepoRoot
        $result.PSObject.Properties.Name | Should -Contain "IsClean"
        $result.IsClean | Should -BeOfType [bool]
    }

    It "存在しないパスでもエラーにならない" {
        { Get-DashboardGitInfo -ProjectRoot "/nonexistent/path/xyz" } | Should -Not -Throw
    }

    It "存在しないパスでは branch が (unknown) を返す" {
        $result = Get-DashboardGitInfo -ProjectRoot "/nonexistent/path/xyz"
        $result.Branch | Should -Be "(unknown)"
    }

    It "結果に必須プロパティが含まれる" {
        $result = Get-DashboardGitInfo -ProjectRoot $script:RepoRoot
        $result.PSObject.Properties.Name | Should -Contain "Branch"
        $result.PSObject.Properties.Name | Should -Contain "LastCommit"
        $result.PSObject.Properties.Name | Should -Contain "LastCommitAge"
        $result.PSObject.Properties.Name | Should -Contain "IsClean"
        $result.PSObject.Properties.Name | Should -Contain "AheadBehind"
    }
}

Describe "Get-DashboardTestInfo" {
    It "リポジトリルートでテストファイル数を返す" {
        $result = Get-DashboardTestInfo -ProjectRoot $script:RepoRoot
        $result.TestFileCount | Should -BeGreaterThan 0
    }

    It "存在しないパスでもエラーにならない" {
        { Get-DashboardTestInfo -ProjectRoot "/nonexistent" } | Should -Not -Throw
    }

    It "存在しないパスではテストファイル数が 0" {
        $result = Get-DashboardTestInfo -ProjectRoot "/nonexistent"
        $result.TestFileCount | Should -Be 0
    }

    It "結果に必須プロパティが含まれる" {
        $result = Get-DashboardTestInfo -ProjectRoot $script:RepoRoot
        $result.PSObject.Properties.Name | Should -Contain "TestFileCount"
        $result.PSObject.Properties.Name | Should -Contain "LastRunTotal"
        $result.PSObject.Properties.Name | Should -Contain "HasResults"
    }
}

Describe "Get-DashboardTokenInfo" {
    It "state.json が存在しない場合にデフォルト値を返す" {
        $result = Get-DashboardTokenInfo -StatePath "/nonexistent/state.json" -ProjectRoot "/nonexistent"
        $result.Zone | Should -Be "Green"
        $result.Used | Should -Be 0
        $result.Remaining | Should -Be 100
        $result.Available | Should -BeFalse
    }

    It "有効な state.json で token 情報を返す" {
        $statePath = Join-Path $TestDrive "state.json"
        @{ token = @{ used = 50 } } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
        $result = Get-DashboardTokenInfo -StatePath $statePath -ProjectRoot $TestDrive
        $result.Used | Should -Be 50
        $result.Remaining | Should -Be 50
        $result.Available | Should -BeTrue
    }

    It "token.used=70 では Zone=Yellow" {
        $statePath = Join-Path $TestDrive "state70.json"
        @{ token = @{ used = 70 } } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
        $result = Get-DashboardTokenInfo -StatePath $statePath -ProjectRoot $TestDrive
        $result.Zone | Should -Be "Yellow"
    }

    It "token.used=85 では Zone=Orange" {
        $statePath = Join-Path $TestDrive "state85.json"
        @{ token = @{ used = 85 } } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
        $result = Get-DashboardTokenInfo -StatePath $statePath -ProjectRoot $TestDrive
        $result.Zone | Should -Be "Orange"
    }

    It "token.used=95 では Zone=Red" {
        $statePath = Join-Path $TestDrive "state95.json"
        @{ token = @{ used = 95 } } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
        $result = Get-DashboardTokenInfo -StatePath $statePath -ProjectRoot $TestDrive
        $result.Zone | Should -Be "Red"
    }
}

Describe "Get-DashboardPhaseInfo" {
    It "state.json が存在しない場合はデフォルトを返す" {
        $result = Get-DashboardPhaseInfo -StatePath "/nonexistent/state.json" -ProjectRoot "/nonexistent"
        $result.Current | Should -Be "Unknown"
        $result.Available | Should -BeFalse
    }

    It "有効な state.json でフェーズ情報を返す" {
        $statePath = Join-Path $TestDrive "statephase.json"
        @{
            execution = @{ phase = "Verify" }
            status    = @{ stable = $true }
            goal      = @{ title  = "テストゴール" }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $statePath -Encoding UTF8

        $result = Get-DashboardPhaseInfo -StatePath $statePath -ProjectRoot $TestDrive
        $result.Current | Should -Be "Verify"
        $result.Stable | Should -BeTrue
        $result.Goal | Should -Be "テストゴール"
        $result.Available | Should -BeTrue
    }
}

Describe "Get-ProjectDashboardInfo" {
    It "必須プロパティを持つオブジェクトを返す" {
        $result = Get-ProjectDashboardInfo -ProjectRoot $script:RepoRoot
        $result.PSObject.Properties.Name | Should -Contain "ProjectRoot"
        $result.PSObject.Properties.Name | Should -Contain "ProjectName"
        $result.PSObject.Properties.Name | Should -Contain "Git"
        $result.PSObject.Properties.Name | Should -Contain "Tests"
        $result.PSObject.Properties.Name | Should -Contain "Token"
        $result.PSObject.Properties.Name | Should -Contain "Phase"
        $result.PSObject.Properties.Name | Should -Contain "Timestamp"
    }

    It "ProjectName がルートのフォルダ名と一致する" {
        $result = Get-ProjectDashboardInfo -ProjectRoot $script:RepoRoot
        $result.ProjectName | Should -Be (Split-Path $script:RepoRoot -Leaf)
    }

    It "Tests.TestFileCount が実際のテストファイル数と一致する" {
        $result = Get-ProjectDashboardInfo -ProjectRoot $script:RepoRoot
        $expected = @(Get-ChildItem -Path (Join-Path $script:RepoRoot "tests/unit") -Filter "*.Tests.ps1").Count
        $result.Tests.TestFileCount | Should -Be $expected
    }
}

Describe "Show-ProjectDashboard" {
    It "呼び出してもエラーにならない" {
        { Show-ProjectDashboard -ProjectRoot $script:RepoRoot } | Should -Not -Throw
    }

    It "戻り値にダッシュボード情報が含まれる" {
        $result = Show-ProjectDashboard -ProjectRoot $script:RepoRoot
        $result | Should -Not -BeNullOrEmpty
        $result.ProjectName | Should -Not -BeNullOrEmpty
    }

    It "-Compact スイッチ付きでもエラーにならない" {
        { Show-ProjectDashboard -ProjectRoot $script:RepoRoot -Compact } | Should -Not -Throw
    }
}
