BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/AuditRepository.psm1") -Force
}

Describe "AuditRepository (File Fallback)" {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-audit-test-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:TempRoot ".git") -Force | Out-Null

        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        Reset-PostgreSqlCircuitBreaker
    }

    It "監査イベントを記録し取得できる" {
        $added = Add-OrchestrationAuditEvent -TaskId "task-1" -EventType "task.created" -Detail @{ actor = "codex" } -ProjectRoot $script:TempRoot
        $added.Ok | Should -BeTrue
        $added.Source | Should -Be "file_fallback"

        $records = @(Get-OrchestrationAuditEvent -TaskId "task-1" -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 1
        $records[0].EventType | Should -Be "task.created"
    }

    It "TaskId未指定なら全件を返す（Limit適用）" {
        1..5 | ForEach-Object {
            Add-OrchestrationAuditEvent -EventType "noop" -ProjectRoot $script:TempRoot | Out-Null
        }

        $records = @(Get-OrchestrationAuditEvent -Limit 3 -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 3
    }

    It "追記専用であり既存レコードを破壊しない" {
        Add-OrchestrationAuditEvent -TaskId "task-1" -EventType "task.created" -ProjectRoot $script:TempRoot | Out-Null
        Add-OrchestrationAuditEvent -TaskId "task-1" -EventType "task.completed" -ProjectRoot $script:TempRoot | Out-Null

        $records = @(Get-OrchestrationAuditEvent -TaskId "task-1" -ProjectRoot $script:TempRoot)
        $records.Count | Should -Be 2
    }
}
