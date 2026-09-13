BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/GoalRouterOrchestration.psm1") -Force

    function New-FakeGoalRoute {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "", Justification = "Pure in-memory test fixture factory, not a system-changing operation.")]
        param()
        [pscustomobject]@{
            Mode           = "auto"
            Primary        = "build"
            Specialized    = ""
            Effective      = "build"
            Confidence     = 0.8
            Reason         = "evidence:phase_mode"
            EvidenceUsed   = @("phase_mode", "ci")
            LockedByUser   = $false
            SessionLocked  = $false
            Plane          = "local"
        }
    }
}

Describe "Sync-GoalRouterOrchestrationEvent (File Fallback)" {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("goal-router-orch-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ".git") -Force | Out-Null

        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "GoalRouterの判定結果をAudit Eventとして記録する" {
        $route = New-FakeGoalRoute
        $result = Sync-GoalRouterOrchestrationEvent -Route $route -ProjectRoot $script:TempRoot
        $result.Ok | Should -BeTrue
        $result.EventType | Should -Be "goal_router.routed"
        $result.Source | Should -Be "file_fallback"
    }
}

Describe "Sync-GoalRouterOrchestrationEvent (実DB接続, Integration)" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
    }

    It "ORCHESTRATION_PG_DSN が設定されていればpostgresql経由で記録される" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $route = New-FakeGoalRoute
        $result = Sync-GoalRouterOrchestrationEvent -Route $route
        $result.Ok | Should -BeTrue
        $result.Source | Should -Be "postgresql"
    }
}
