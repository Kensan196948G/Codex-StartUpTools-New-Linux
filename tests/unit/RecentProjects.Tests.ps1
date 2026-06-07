BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:RepoRoot "scripts/lib/RecentProjects.ps1")
}

Describe "Get-RecentProject" {
    It "履歴がなければ空配列を返す" {
        @(Get-RecentProject -HistoryPath (Join-Path $TestDrive "missing.json")).Count | Should -Be 0
    }

    It "旧形式の文字列配列を正規化する" {
        $path = Join-Path $TestDrive "legacy.json"
        '{"projects":["MyProject"]}' | Set-Content -Path $path -Encoding UTF8
        $result = Get-RecentProject -HistoryPath $path
        $result[0].project | Should -Be "MyProject"
        $result[0].tool | Should -BeNullOrEmpty
    }
}

Describe "Update-RecentProject" {
    It "新規履歴を作成する" {
        $path = Join-Path $TestDrive "new\recent.json"
        Update-RecentProject -ProjectName "Alpha" -Tool "codex" -Mode "local" -HistoryPath $path
        (Get-RecentProject -HistoryPath $path)[0].project | Should -Be "Alpha"
    }

    It "重複を削除して先頭に再追加する" {
        $path = Join-Path $TestDrive "dedup.json"
        Update-RecentProject -ProjectName "Alpha" -HistoryPath $path
        Update-RecentProject -ProjectName "Beta" -HistoryPath $path
        Update-RecentProject -ProjectName "Alpha" -HistoryPath $path
        $result = Get-RecentProject -HistoryPath $path
        $result[0].project | Should -Be "Alpha"
        @($result).Count | Should -Be 2
    }
}

Describe "Test-RecentProjectsEnabled" {
    It "enabled=true かつ historyFile があれば true" {
        $config = [pscustomobject]@{
            recentProjects = [pscustomobject]@{ enabled = $true; historyFile = "recent.json" }
        }
        Test-RecentProjectsEnabled -Config $config | Should -BeTrue
    }
}
