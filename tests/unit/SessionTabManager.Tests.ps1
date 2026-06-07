BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/SessionTabManager.psm1") -Force
}

Describe "Get-SessionDir" {
    It "明示された config dir を返す" {
        Get-SessionDir -ConfigSessionsDir "C:\custom\sessions" | Should -Be "C:\custom\sessions"
    }

    It "未指定なら .codex-startup\\sessions で終わる" {
        (Get-SessionDir) | Should -Match "\.codex-startup[/\\]sessions$"
    }

    It "環境変数を展開する" {
        $env:CODEX_TEST_SESSIONS = $TestDrive
        try {
            (Get-SessionDir -ConfigSessionsDir '%CODEX_TEST_SESSIONS%/sessions') | Should -Be (Join-Path $TestDrive "sessions")
        }
        finally {
            Remove-Item Env:CODEX_TEST_SESSIONS -ErrorAction SilentlyContinue
        }
    }
}

Describe "New-SessionId" {
    It "timestamp-project 形式を返す" {
        (New-SessionId -Project "myproj") | Should -Match "^\d{8}-\d{6}-myproj$"
    }

    It "空白をアンダースコアに変換する" {
        (New-SessionId -Project "my project") | Should -Match "-my_project$"
    }
}

Describe "Session persistence" {
    It "New-SessionInfo は running 状態で作成する" {
        $session = New-SessionInfo -Project "testproj" -DurationMinutes 60 -Trigger "manual" -ConfigSessionsDir (Join-Path $TestDrive "sessions1")
        $session.status | Should -Be "running"
        $session.project | Should -Be "testproj"
        $session.max_duration_minutes | Should -Be 60
    }

    It "Get-SessionInfo は存在しない session で null を返す" {
        Get-SessionInfo -SessionId "missing" -ConfigSessionsDir (Join-Path $TestDrive "sessions2") | Should -BeNullOrEmpty
    }

    It "Save / Get で project を round-trip できる" {
        $dir = Join-Path $TestDrive "sessions3"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $session = New-SessionInfo -Project "roundtrip" -ConfigSessionsDir $dir
        $loaded = Get-SessionInfo -SessionId $session.sessionId -ConfigSessionsDir $dir
        $loaded.project | Should -Be "roundtrip"
        $loaded.status | Should -Be "running"
    }
}

Describe "Get-ActiveSession" {
    It "sessions dir が無ければ null" {
        Get-ActiveSession -ConfigSessionsDir (Join-Path $TestDrive "no-sessions") | Should -BeNullOrEmpty
    }

    It "running session を返す" {
        $dir = Join-Path $TestDrive "active-one"
        $null = New-SessionInfo -Project "active-test" -ConfigSessionsDir $dir
        $result = Get-ActiveSession -ConfigSessionsDir $dir
        $result.project | Should -Be "active-test"
        $result.status | Should -Be "running"
    }
}
