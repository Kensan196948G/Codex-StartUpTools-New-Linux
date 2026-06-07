BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/StatuslineManager.psm1") -Force
}

Describe "Get-GlobalStatusLineConfig" {
    It "settings file がなければ found=false を返す" {
        $result = Get-GlobalStatusLineConfig -SettingsPath (Join-Path $TestDrive "nonexistent.json")
        $result.found | Should -BeFalse
        $result.statusLine | Should -BeNullOrEmpty
    }

    It "要求された path を結果に保持する" {
        $path = Join-Path $TestDrive "check-path.json"
        (Get-GlobalStatusLineConfig -SettingsPath $path).path | Should -Be $path
    }

    It "settings file があれば found=true を返す" {
        $path = Join-Path $TestDrive "settings-exist.json"
        '{"version": 1}' | Set-Content $path -Encoding UTF8
        (Get-GlobalStatusLineConfig -SettingsPath $path).found | Should -BeTrue
    }

    It "statusLine キーがあれば値を返す" {
        $path = Join-Path $TestDrive "settings-with-sl.json"
        '{"statusLine": {"enabled": true, "format": "test"}}' | Set-Content $path -Encoding UTF8
        $result = Get-GlobalStatusLineConfig -SettingsPath $path
        $result.statusLine | Should -Not -BeNullOrEmpty
        $result.statusLine.enabled | Should -BeTrue
    }

    It "statusLine がなければ null を返す" {
        $path = Join-Path $TestDrive "settings-no-sl.json"
        '{"other": "value"}' | Set-Content $path -Encoding UTF8
        $result = Get-GlobalStatusLineConfig -SettingsPath $path
        $result.found | Should -BeTrue
        $result.statusLine | Should -BeNullOrEmpty
    }

    It "不正 JSON なら throw する" {
        $path = Join-Path $TestDrive "settings-bad.json"
        "NOT VALID JSON {{{{" | Set-Content $path -Encoding UTF8
        { Get-GlobalStatusLineConfig -SettingsPath $path } | Should -Throw
    }

    It "path 未指定なら .codex\\settings.json を使う" {
        (Get-GlobalStatusLineConfig).path | Should -Match "\.codex[/\\]settings\.json$"
    }
}
