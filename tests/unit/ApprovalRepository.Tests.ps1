BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/ApprovalRepository.psm1") -Force
}

Describe "ApprovalRepository (File Fallback)" {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-approval-test-" + [guid]::NewGuid())
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

    It "Approvalを記録し取得できる" {
        $added = Add-OrchestrationApproval -RunId "run-1" -Gate "high-risk-merge" -Decision "approved" -DecidedBy "user" -Reason "reviewed" -ProjectRoot $script:TempRoot
        $added.Ok | Should -BeTrue
        $added.Source | Should -Be "file_fallback"

        $records = @(Get-OrchestrationApproval -RunId "run-1" -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 1
        $records[0].Decision | Should -Be "approved"
        $records[0].Gate | Should -Be "high-risk-merge"
    }

    It "rejectedも記録できる" {
        $added = Add-OrchestrationApproval -Gate "database-migration" -Decision "rejected" -ProjectRoot $script:TempRoot
        $added.Decision | Should -Be "rejected"
    }

    It "RunId未指定なら全件を返す" {
        Add-OrchestrationApproval -RunId "run-1" -Gate "release" -Decision "approved" -ProjectRoot $script:TempRoot | Out-Null
        Add-OrchestrationApproval -RunId "run-2" -Gate "release" -Decision "approved" -ProjectRoot $script:TempRoot | Out-Null

        $records = @(Get-OrchestrationApproval -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 2
    }
}

Describe "ApprovalRepository (実DB接続, Integration)" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
    }

    It "ORCHESTRATION_PG_DSN が設定されていればApprovalがpostgresql経由で記録される" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $added = Add-OrchestrationApproval -Gate "integration-test-gate" -Decision "approved" -DecidedBy "pester"
        $added.Ok | Should -BeTrue
        $added.Source | Should -Be "postgresql"
    }
}

Describe "Human Gate (接続未設定)" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "Request-OrchestrationHumanApprovalはOk=falseを返す（File Fallbackは持たない）" {
        $result = Request-OrchestrationHumanApproval -Gate "high-risk-merge" -Reason "test"
        $result.Ok | Should -BeFalse
        $result.Id | Should -BeNullOrEmpty
    }

    It "Get-PendingOrchestrationHumanApprovalは空配列を返す" {
        @(Get-PendingOrchestrationHumanApproval).Count | Should -Be 0
    }
}

Describe "Human Gate (実DB接続, Integration)" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
    }

    It "Request→ListPending→Approveの一連が動作する" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $requested = Request-OrchestrationHumanApproval -Gate "database-migration" -Reason "phase3 integration test"
        $requested.Ok | Should -BeTrue
        $requested.Id | Should -Not -BeNullOrEmpty

        $pending = @(Get-PendingOrchestrationHumanApproval | Where-Object { $_.Id -eq $requested.Id })
        $pending.Count | Should -Be 1
        $pending[0].Gate | Should -Be "database-migration"

        $approved = Approve-OrchestrationHumanGate -Id $requested.Id -DecidedBy "pester" -Reason "approved in test"
        $approved.Ok | Should -BeTrue
        $approved.Updated | Should -BeTrue

        # 承認済みなのでpending一覧から消える
        $stillPending = @(Get-PendingOrchestrationHumanApproval | Where-Object { $_.Id -eq $requested.Id })
        $stillPending.Count | Should -Be 0

        # 二重承認は更新されない（既にpendingではないため）
        $secondApprove = Approve-OrchestrationHumanGate -Id $requested.Id -DecidedBy "pester"
        $secondApprove.Ok | Should -BeTrue
        $secondApprove.Updated | Should -BeFalse
    }

    It "Request→Denyの一連が動作する" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $requested = Request-OrchestrationHumanApproval -Gate "secret-change" -Reason "phase3 integration test"
        $requested.Ok | Should -BeTrue

        $denied = Deny-OrchestrationHumanGate -Id $requested.Id -DecidedBy "pester" -Reason "denied in test"
        $denied.Ok | Should -BeTrue
        $denied.Updated | Should -BeTrue
    }
}
