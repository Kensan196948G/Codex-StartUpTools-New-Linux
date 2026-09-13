BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/OrchestrationRepository.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/TaskQueue.psm1") -Force
}

Describe "Get-OrchestrationWorkerId" {
    It "空でない文字列を返す" {
        (Get-OrchestrationWorkerId) | Should -Not -BeNullOrEmpty
    }
}

Describe "TaskQueue (接続未設定)" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "Get-NextOrchestrationTaskはOk=falseを返す" {
        $result = Get-NextOrchestrationTask -Worker "test-worker"
        $result.Ok | Should -BeFalse
    }

    It "Reset-StaleOrchestrationTaskはOk=falseを返す" {
        $result = Reset-StaleOrchestrationTask
        $result.Ok | Should -BeFalse
    }

    It "Get-StaleOrchestrationTaskは空配列を返す" {
        @(Get-StaleOrchestrationTask).Count | Should -Be 0
    }
}

Describe "TaskQueue (実DB接続, Integration)" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
    }

    It "ORCHESTRATION_PG_DSN が設定されていればLease→Heartbeat→Completeの一連が動作する" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $task = Add-OrchestrationTask -TaskType "queue-test" -Payload @{ note = "phase3" } -Priority 1000
        $task.Source | Should -Be "postgresql"

        $worker = "pester-worker-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $leased = Get-NextOrchestrationTask -Worker $worker -LeaseSeconds 60
        $leased.Ok | Should -BeTrue
        $leased.Task | Should -Not -BeNullOrEmpty
        $leased.Task.Id | Should -Be $task.Id

        $heartbeat = Send-OrchestrationTaskHeartbeat -Id $task.Id -Worker $worker -LeaseSeconds 120
        $heartbeat.Ok | Should -BeTrue
        $heartbeat.Updated | Should -BeTrue

        $completed = Complete-OrchestrationTask -Id $task.Id -Worker $worker
        $completed.Ok | Should -BeTrue
        $completed.Updated | Should -BeTrue

        # 完了済みタスクは再度リースされない
        $again = Get-NextOrchestrationTask -Worker $worker
        if ($again.Task) {
            $again.Task.Id | Should -Not -Be $task.Id
        }
    }

    It "リース中のタスクは他Workerに再リースされない（FOR UPDATE SKIP LOCKEDの効果を間接確認）" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $task = Add-OrchestrationTask -TaskType "queue-test-exclusive" -Priority 1000
        $workerA = "pester-worker-a-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $workerB = "pester-worker-b-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

        $leasedA = Get-NextOrchestrationTask -Worker $workerA -LeaseSeconds 300
        $leasedA.Ok | Should -BeTrue
        $leasedA.Task.Id | Should -Be $task.Id

        $leasedB = Get-NextOrchestrationTask -Worker $workerB -LeaseSeconds 300
        if ($leasedB.Task) {
            $leasedB.Task.Id | Should -Not -Be $task.Id
        }

        Complete-OrchestrationTask -Id $task.Id -Worker $workerA | Out-Null
    }

    It "期限切れリースはRecoverStaleでpendingへ戻る" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        $task = Add-OrchestrationTask -TaskType "queue-test-stale" -Priority 1000
        $worker = "pester-worker-stale-" + [guid]::NewGuid().ToString("N").Substring(0, 8)

        # 即座に期限切れになるリース（-1秒）を作る
        $leased = Get-NextOrchestrationTask -Worker $worker -LeaseSeconds -1
        $leased.Ok | Should -BeTrue
        $leased.Task.Id | Should -Be $task.Id

        $stale = @(Get-StaleOrchestrationTask | Where-Object { $_.Id -eq $task.Id })
        $stale.Count | Should -Be 1

        $recovered = Reset-StaleOrchestrationTask
        $recovered.Ok | Should -BeTrue
        $recovered.Recovered | Should -BeGreaterOrEqual 1

        $fetched = Get-OrchestrationTask -Id $task.Id
        $fetched.Status | Should -Be "pending"

        # 検証後、後続テスト（同一DB上）に影響しないようcompletedにしておく
        $cleanupWorker = "pester-cleanup-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
        $reLeased = Get-NextOrchestrationTask -Worker $cleanupWorker
        if ($reLeased.Task -and $reLeased.Task.Id -eq $task.Id) {
            Complete-OrchestrationTask -Id $task.Id -Worker $cleanupWorker | Out-Null
        }
    }
}
