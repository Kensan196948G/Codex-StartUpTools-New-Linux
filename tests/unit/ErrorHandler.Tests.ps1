BeforeAll {
    Import-Module "$PSScriptRoot/../../scripts/lib/ErrorHandler.psm1" -Force
}

Describe "ErrorHandler module" {
    It "exports Show-CategorizedError" {
        Get-Command -Name "Show-CategorizedError" -Module "ErrorHandler" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "exports Get-ErrorCategory" {
        Get-Command -Name "Get-ErrorCategory" -Module "ErrorHandler" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "Get-ErrorCategory" {
    It "codex not found を TOOL_NOT_FOUND に分類する" {
        (Get-ErrorCategory -ErrorMessage "codex not found").ToString() | Should -Be "TOOL_NOT_FOUND"
    }

    It "api key missing を API_KEY_MISSING に分類する" {
        (Get-ErrorCategory -ErrorMessage "api key missing").ToString() | Should -Be "API_KEY_MISSING"
    }

    It "connection timed out を NETWORK_TIMEOUT に分類する" {
        (Get-ErrorCategory -ErrorMessage "connection timed out").ToString() | Should -Be "NETWORK_TIMEOUT"
    }

    It "不明な文面は UNKNOWN に分類する" {
        (Get-ErrorCategory -ErrorMessage "原因不明のエラーです").ToString() | Should -Be "UNKNOWN"
    }
}

Describe "Show-CategorizedError" {
    It "ThrowAfter=true なら例外を投げる" {
        { Show-CategorizedError -Category "CONFIG_INVALID" -Message "テスト設定エラー" -ThrowAfter $true 6>$null } | Should -Throw
    }

    It "ThrowAfter=false なら例外を投げない" {
        { Show-CategorizedError -Category "DEPENDENCY_MISSING" -Message "依存関係テスト" -ThrowAfter $false 6>$null } | Should -Not -Throw
    }
}

Describe "Show-Error" {
    It "自動分類して例外を投げる" {
        { Show-Error -Message "codex not found" -ThrowAfter $true 6>$null } | Should -Throw
    }

    It "ThrowAfter=false なら例外を投げない" {
        { Show-Error -Message "テストエラー通知" -ThrowAfter $false 6>$null } | Should -Not -Throw
    }
}
