BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/OrchestrationRepository.psm1") -Force
}

Describe "OrchestrationRepository (File Fallback)" {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-repo-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ".git") -Force | Out-Null

        # 接続未設定を確実にし、常にFile Fallback経路をテストする。
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Reset-PostgreSqlCircuitBreaker
    }

    It "Task を追加し File Fallback 経由で取得できる" {
        $added = Add-OrchestrationTask -TaskType "demo" -Payload @{ foo = "bar" } -ProjectRoot $script:TempRoot
        $added.Ok | Should -BeTrue
        $added.Source | Should -Be "file_fallback"

        $fetched = Get-OrchestrationTask -Id $added.Id -ProjectRoot $script:TempRoot
        $fetched | Should -Not -BeNullOrEmpty
        $fetched.TaskType | Should -Be "demo"
        $fetched.Status | Should -Be "pending"
        $fetched.Source | Should -Be "file_fallback"
    }

    It "存在しないIdは null を返す" {
        (Get-OrchestrationTask -Id "does-not-exist" -ProjectRoot $script:TempRoot) | Should -BeNullOrEmpty
    }

    It "Task状態を更新できる（更新イベントとして追記される）" {
        $added = Add-OrchestrationTask -TaskType "demo" -ProjectRoot $script:TempRoot
        $updated = Set-OrchestrationTaskStatus -Id $added.Id -Status "done" -ProjectRoot $script:TempRoot
        $updated.Ok | Should -BeTrue
        $updated.Source | Should -Be "file_fallback"
    }

    It "Run を追加できる" {
        $task = Add-OrchestrationTask -TaskType "demo" -ProjectRoot $script:TempRoot
        $run = Add-OrchestrationRun -TaskId $task.Id -Metadata @{ note = "first" } -ProjectRoot $script:TempRoot
        $run.Ok | Should -BeTrue
        $run.Source | Should -Be "file_fallback"
        $run.TaskId | Should -Be $task.Id
    }

    It "Run状態を更新できる" {
        $task = Add-OrchestrationTask -TaskType "demo" -ProjectRoot $script:TempRoot
        $run = Add-OrchestrationRun -TaskId $task.Id -ProjectRoot $script:TempRoot
        $updated = Set-OrchestrationRunStatus -Id $run.Id -Status "completed" -Ended -ProjectRoot $script:TempRoot
        $updated.Ok | Should -BeTrue
        $updated.Source | Should -Be "file_fallback"
    }
}
