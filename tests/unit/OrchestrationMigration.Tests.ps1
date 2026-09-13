BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/OrchestrationMigration.psm1") -Force
}

Describe "Get-OrchestrationMigrationFile" {
    BeforeEach {
        $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-migrations-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
        Set-Content -Path (Join-Path $script:TempDir "0002_second.sql") -Value "SELECT 1;" -Encoding UTF8
        Set-Content -Path (Join-Path $script:TempDir "0001_first.sql") -Value "SELECT 1;" -Encoding UTF8
    }

    AfterEach {
        Remove-Item -Path $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "ファイル名の昇順でバージョンを返す" {
        $files = @(Get-OrchestrationMigrationFile -MigrationsDir $script:TempDir)
        $files.Count | Should -Be 2
        $files[0].Version | Should -Be "0001_first"
        $files[1].Version | Should -Be "0002_second"
    }

    It "リポジトリの db/migrations に初期migrationが存在する" {
        $files = @(Get-OrchestrationMigrationFile)
        $files.Count | Should -BeGreaterOrEqual 1
        $files[0].Version | Should -Be "0001_init"
    }
}

Describe "Get-OrchestrationAppliedMigration (接続未設定)" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "接続不可の場合は Ok=false を返す" {
        $result = Get-OrchestrationAppliedMigration
        $result.Ok | Should -BeFalse
        @($result.Versions).Count | Should -Be 0
    }
}

Describe "Invoke-OrchestrationMigration (接続未設定)" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN")
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $null)
        Reset-PostgreSqlCircuitBreaker
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN", $script:OriginalDsn)
        Reset-PostgreSqlCircuitBreaker
    }

    It "postgresql未起動を理由にOk=falseを返す" {
        $result = Invoke-OrchestrationMigration -DryRun
        $result.Ok | Should -BeFalse
        $result.Reason | Should -Match "not healthy"
    }
}

Describe "Invoke-OrchestrationMigration (実DB接続, Integration)" {
    It "ORCHESTRATION_PG_DSN が設定されていればdry-runでpending一覧を取得できる" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        Reset-PostgreSqlCircuitBreaker
        $result = Invoke-OrchestrationMigration -DryRun
        $result.Ok | Should -BeTrue
    }

    It "適用後は再度dry-runしてもpendingが空でエラーにならない（冪等性・空配列メンバーアクセスの回帰確認）" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        Reset-PostgreSqlCircuitBreaker
        Invoke-OrchestrationMigration | Out-Null

        Reset-PostgreSqlCircuitBreaker
        $result = Invoke-OrchestrationMigration -DryRun
        $result.Ok | Should -BeTrue
        @($result.Pending).Count | Should -Be 0
        @($result.Applied) | Should -Contain "0001_init"
    }
}
