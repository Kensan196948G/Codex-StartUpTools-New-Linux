BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot "scripts/lib/PostgreSqlStore.psm1") -Force
}

Describe "Get-PostgreSqlConnectionInfo" {
    BeforeEach {
        $script:OriginalDsn = [System.Environment]::GetEnvironmentVariable("ORCHESTRATION_PG_DSN_TEST")
    }

    AfterEach {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN_TEST", $script:OriginalDsn)
    }

    It "環境変数が未設定なら Available=false を返す" {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN_TEST", $null)
        $info = Get-PostgreSqlConnectionInfo -DsnEnvVar "ORCHESTRATION_PG_DSN_TEST"
        $info.Available | Should -BeFalse
        $info.Dsn | Should -BeNullOrEmpty
    }

    It "環境変数が設定されていれば Available=true を返す" {
        [System.Environment]::SetEnvironmentVariable("ORCHESTRATION_PG_DSN_TEST", "postgresql://example/test")
        $info = Get-PostgreSqlConnectionInfo -DsnEnvVar "ORCHESTRATION_PG_DSN_TEST"
        $info.Available | Should -BeTrue
        $info.Dsn | Should -Be "postgresql://example/test"
    }
}

Describe "Test-PostgreSqlClientTool" {
    It "boolean を返す" {
        (Test-PostgreSqlClientTool) | Should -BeOfType [bool]
    }
}

Describe "PostgreSQL Circuit Breaker" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
        Set-PostgreSqlCircuitBreakerOption -FailureThreshold 3 -OpenSeconds 30
    }

    AfterEach {
        Reset-PostgreSqlCircuitBreaker
        Set-PostgreSqlCircuitBreakerOption -FailureThreshold 5 -OpenSeconds 30
    }

    It "初期状態は閉じている" {
        (Get-PostgreSqlCircuitBreakerState).IsOpen | Should -BeFalse
    }

    It "閾値未満の失敗では開かない" {
        Add-PostgreSqlCircuitBreakerFailure
        Add-PostgreSqlCircuitBreakerFailure
        (Get-PostgreSqlCircuitBreakerState).IsOpen | Should -BeFalse
    }

    It "閾値に達すると開く" {
        Add-PostgreSqlCircuitBreakerFailure
        Add-PostgreSqlCircuitBreakerFailure
        Add-PostgreSqlCircuitBreakerFailure
        (Get-PostgreSqlCircuitBreakerState).IsOpen | Should -BeTrue
    }

    It "Resetで閉じた状態に戻る" {
        Add-PostgreSqlCircuitBreakerFailure
        Add-PostgreSqlCircuitBreakerFailure
        Add-PostgreSqlCircuitBreakerFailure
        Reset-PostgreSqlCircuitBreaker
        $state = Get-PostgreSqlCircuitBreakerState
        $state.IsOpen | Should -BeFalse
        $state.FailureCount | Should -Be 0
    }
}

Describe "Invoke-PostgreSqlCommand (接続未設定)" {
    BeforeEach {
        Reset-PostgreSqlCircuitBreaker
    }

    It "環境変数が未設定なら即座に Ok=false を返す" {
        $result = Invoke-PostgreSqlCommand -Sql "SELECT 1;" -DsnEnvVar "ORCHESTRATION_PG_DSN_NOT_SET_XYZ"
        $result.Ok | Should -BeFalse
        $result.Reason | Should -Match "not set"
    }
}

Describe "Test-PostgreSqlHealth (接続未設定)" {
    It "環境変数が未設定なら Healthy=false を返す" {
        $health = Test-PostgreSqlHealth -DsnEnvVar "ORCHESTRATION_PG_DSN_NOT_SET_XYZ"
        $health.Healthy | Should -BeFalse
    }
}

Describe "Invoke-PostgreSqlCommand (実DB接続, Integration)" {
    It "ORCHESTRATION_PG_DSN が設定されていれば SELECT 1 が成功する" -Skip:(-not $env:ORCHESTRATION_PG_DSN) {
        Reset-PostgreSqlCircuitBreaker
        $result = Invoke-PostgreSqlCommand -Sql "SELECT 1;"
        $result.Ok | Should -BeTrue
    }
}
