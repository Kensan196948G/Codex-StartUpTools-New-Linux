BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/CodexGoalProjection.psm1") -Force
}

Describe "Sync-CodexGoalProjection (Codex Goal DB不在)" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        Reset-PostgreSqlCircuitBreaker
        $script:FakeCodexHome = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-home-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:FakeCodexHome -Force | Out-Null
    }

    AfterEach {
        Remove-Item -Path $script:FakeCodexHome -Recurse -Force -ErrorAction SilentlyContinue
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "Codex Goal DBが無ければOk=falseで縮退する（例外にならない）" {
        $result = Sync-CodexGoalProjection -CodexHome $script:FakeCodexHome
        $result.Ok | Should -BeFalse
        $result.Reason | Should -Match "codex-goal-db"
        $result.Synced | Should -Be 0
    }
}

Describe "Sync-CodexGoalProjection (PostgreSQL未接続)" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "実際の~/.codex/goals DBがあってもPostgreSQL未接続ならOk=falseで縮退する" {
        $result = Sync-CodexGoalProjection
        # Codex Goal DB自体が無い環境ではcodex-goal-db側の理由になるため、
        # どちらの縮退経路でもOk=falseであることのみを確認する。
        $result.Ok | Should -BeFalse
    }
}

Describe "Sync-CodexGoalProjection / Get-CodexGoalProjection (実DB接続, Integration)" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
    }

    It "ORCHESTRATION_PG_DSN が設定されていれば同期がOkを返す（Codex Goal DBが無くても縮退でOk=falseは許容）" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $result = Sync-CodexGoalProjection
        # Codex Goal DBの有無に関わらず例外を投げないことを確認する。
        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties["Ok"] | Should -Not -BeNullOrEmpty
    }

    It "Set-CodexGoalProjectionRecordで書き込んだ内容をGet-CodexGoalProjectionで取得できる" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $goal = [pscustomobject]@{
            ThreadId        = "test-thread-" + [guid]::NewGuid()
            GoalId          = "test-goal-1"
            Objective       = "integration test objective"
            Status          = "active"
            TokenBudget     = 1000
            TokensUsed      = 10
            TimeUsedSeconds = 5
            UpdatedAtMs     = 1234567890
        }

        $writeResult = Set-CodexGoalProjectionRecord -Goal $goal
        $writeResult.Ok | Should -BeTrue

        $records = @(Get-CodexGoalProjection -Status "active" | Where-Object { $_.ThreadId -eq $goal.ThreadId })
        $records.Count | Should -Be 1
        $records[0].Objective | Should -Be "integration test objective"
        $records[0].GoalId | Should -Be "test-goal-1"
    }
}
